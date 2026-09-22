#!/usr/bin/env python3
"""Serve a persistent, zoom-aware local viewer for Graphify artifacts.

The server reads graphify-out/graph.json plus optional structural and call
artifacts.  It keeps the input read-only, reloads derived data when any input
changes, and exposes bounded region, file/module, and function subgraphs.
Only Python's standard library is required.
"""

import argparse
import hashlib
import importlib.util
import json
import mimetypes
import pathlib
import re
import sys
import threading
import urllib.parse
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DEFAULT_GRAPH = "graphify-out/graph.json"
DEFAULT_STRUCTURAL_CANDIDATES = (
    "graphify-out/graph-structural.json",
    "graphify-out/graph-structural.regions.json",
)
DEFAULT_CALL_CANDIDATES = (
    "graphify-out/calls.json",
    "graphify-out/graph-calls.json",
    "graphify-out/call-graph.json",
)
DEFAULT_FRONTEND = pathlib.Path(__file__).resolve().parent.parent / "web" / "dist"
MAX_SOURCE_BYTES = 256 * 1024
CALL_RELATIONS = {
    "call",
    "calls",
    "invokes",
    "invocation",
    "function_call",
    "function-call",
    "call_edge",
    "call-edge",
}


class CliError(Exception):
    """An actionable graph input or request error."""


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Serve a persistent local Graphify graph viewer."
    )
    parser.add_argument(
        "--graph",
        "--input",
        default=DEFAULT_GRAPH,
        metavar="PATH",
        help="Graphify graph JSON (default: graphify-out/graph.json).",
    )
    parser.add_argument(
        "--structural",
        default=None,
        metavar="PATH",
        help="Optional structural graph or region-plan JSON.",
    )
    parser.add_argument(
        "--calls",
        default=None,
        metavar="PATH",
        help="Optional call-edge artifact JSON.",
    )
    parser.add_argument(
        "--frontend",
        default=str(DEFAULT_FRONTEND),
        metavar="PATH",
        help="Built Svelte viewer directory (default: web/dist).",
    )
    parser.add_argument(
        "--source-root",
        default=".",
        metavar="PATH",
        help="Root directory allowed for source inspection (default: .).",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind address.")
    parser.add_argument("--port", type=int, default=8765, help="Bind port.")
    parser.add_argument(
        "--max-visible",
        type=int,
        default=500,
        metavar="N",
        help="Maximum nodes and edges returned or rendered (default: 500).",
    )
    return parser.parse_args(argv)


def _graphify_helpers():
    path = pathlib.Path(__file__).with_name("fm-graphify-embed.py")
    spec = importlib.util.spec_from_file_location("fm_graphify_embed", path)
    if spec is None or spec.loader is None:
        raise CliError("could not load Graphify field helpers")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _read_json(path, description):
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except FileNotFoundError:
        raise CliError("{} does not exist: {}".format(description, path))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise CliError("could not read {} {}: {}".format(description, path, exc))
    return value


def _first_field(helper, value, names):
    if not isinstance(value, dict):
        return ""
    return helper.first_field(value, names)


def _edge_dicts(helper, payload, description):
    """Return normalized raw edge dictionaries from common artifact shapes."""
    if isinstance(payload, list):
        raw_edges = payload
    elif isinstance(payload, dict):
        raw_edges = None
        for key in ("edges", "links", "calls", "call_edges"):
            candidate = payload.get(key)
            if isinstance(candidate, list):
                raw_edges = candidate
                break
        if raw_edges is None:
            calls = payload.get("calls")
            if isinstance(calls, dict):
                raw_edges = []
                for source, targets in calls.items():
                    if isinstance(targets, list):
                        for target in targets:
                            raw_edges.append({"source": source, "target": target, "type": "call"})
                    elif isinstance(targets, str):
                        raw_edges.append({"source": source, "target": targets, "type": "call"})
            else:
                raw_edges = []
    else:
        raise CliError("{} must be a JSON object or array".format(description))

    edges = []
    for index, edge in enumerate(raw_edges):
        if not isinstance(edge, dict):
            raise CliError("{} edge {} must be an object".format(description, index))
        source = ""
        target = ""
        for name in ("source", "from", "src", "source_id", "sourceId", "caller", "caller_id", "from_id"):
            if edge.get(name) is not None:
                source = str(edge[name]).strip()
                if source:
                    break
        for name in ("target", "to", "dst", "target_id", "targetId", "callee", "callee_id", "to_id"):
            if edge.get(name) is not None:
                target = str(edge[name]).strip()
                if target:
                    break
        if not source or not target:
            raise CliError("{} edge {} needs source and target ids".format(description, index))
        relation = _first_field(
            helper, edge, ("relation", "type", "kind", "label", "edge_type")
        ) or "call"
        edges.append({"source": source, "target": target, "relation": relation})
    return edges


def _is_call(relation):
    normalized = str(relation).strip().lower().replace(" ", "_")
    return normalized in CALL_RELATIONS or "call" in normalized or "invoke" in normalized


def _node_region(helper, node):
    return _first_field(
        helper,
        node,
        (
            "structural_region_id",
            "structuralRegionId",
            "region_id",
            "regionId",
            "region",
            "cluster_id",
            "clusterId",
            "semantic_cluster_id",
            "semanticClusterId",
        ),
    )


def _node_module(helper, node):
    return _first_field(
        helper,
        node,
        ("module", "module_id", "moduleId", "package", "namespace"),
    )
def _node_source_path(helper, node):
    return helper.node_source_path(node) or _first_field(
        helper, node, ("source_file", "sourceFile")
    )


def _has_test_marker(values):
    for value in values:
        if re.search(r"(?:^|[^a-z0-9])(test|tests|spec|fixture)(?:$|[^a-z0-9])", str(value).casefold()):
            return True
    return False


def _signature(path):
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise CliError("could not inspect {}: {}".format(path, exc))
    return (stat.st_mtime_ns, stat.st_size)


def _discover(optional_path, candidates):
    if optional_path:
        return pathlib.Path(optional_path)
    for candidate in candidates:
        path = pathlib.Path(candidate)
        if path.exists():
            return path
    return None


def _stable_region_id(node_ids):
    digest = hashlib.sha256("\0".join(sorted(node_ids)).encode("utf-8")).hexdigest()[:16]
    return "structural-region-" + digest


def _connected_regions(node_ids, edges):
    parent = {node_id: node_id for node_id in node_ids}

    def find(value):
        while parent[value] != value:
            parent[value] = parent[parent[value]]
            value = parent[value]
        return value

    for edge in edges:
        if edge["relation"] == "semantically_similar_to":
            continue
        if edge["source"] not in parent or edge["target"] not in parent:
            continue
        left, right = find(edge["source"]), find(edge["target"])
        if left != right:
            parent[right] = left
    groups = defaultdict(list)
    for node_id in sorted(node_ids):
        groups[find(node_id)].append(node_id)
    regions = {}
    for members in groups.values():
        region_id = _stable_region_id(members)
        for node_id in members:
            regions[node_id] = region_id
    return regions


def _region_overlay(helper, payload):
    regions = {}
    if isinstance(payload, dict):
        clusters = payload.get("clusters")
        if isinstance(clusters, list):
            for cluster in clusters:
                if not isinstance(cluster, dict):
                    continue
                region_id = _first_field(helper, cluster, ("cluster_id", "region_id", "id"))
                members = cluster.get("node_ids", cluster.get("nodes", []))
                if region_id and isinstance(members, list):
                    for member in members:
                        if isinstance(member, dict):
                            member = member.get("id", member.get("node_id"))
                        if member is not None:
                            regions[str(member)] = region_id
        try:
            structural_records = helper.normalize_nodes(payload)
        except Exception:
            structural_records = []
        for record in structural_records:
            region_id = _node_region(helper, record.node)
            if region_id:
                regions[record.node_id] = region_id
    return regions


def _parse_graph(helper, payload):
    if not isinstance(payload, dict):
        raise CliError("graph input must be a JSON object")
    try:
        records = helper.normalize_nodes(payload)
        _, raw_edges = helper.normalize_edges(payload)
    except helper.CliError as exc:
        raise CliError(str(exc))
    nodes = {}
    for record in records:
        node = record.node
        nodes[record.node_id] = {
            "id": record.node_id,
            "label": helper.node_label(node, record.node_id),
            "source_path": _node_source_path(helper, node),
            "module": _node_module(helper, node),
            "kind": _first_field(helper, node, ("kind", "type", "category", "node_type")),
            "region": _node_region(helper, node),
            "raw": node,
        }
    edges = []
    for _raw, source, target, relation in raw_edges:
        edges.append({"source": source, "target": target, "relation": relation})
    return nodes, edges


def _load_snapshot(graph_path, structural_path, calls_path, max_visible, source_root):
    helper = _graphify_helpers()
    graph = _read_json(graph_path, "graph input")
    nodes, graph_edges = _parse_graph(helper, graph)
    node_ids = set(nodes)
    valid_edges = [
        edge
        for edge in graph_edges
        if edge["source"] in node_ids and edge["target"] in node_ids
    ]
    regions = {node_id: node["region"] for node_id, node in nodes.items() if node["region"]}
    if structural_path is not None:
        structural = _read_json(structural_path, "structural artifact")
        regions.update(_region_overlay(helper, structural))
    derived = _connected_regions(node_ids, valid_edges)
    for node_id in sorted(node_ids):
        regions.setdefault(node_id, derived[node_id])
    for node_id, region_id in regions.items():
        if node_id in nodes:
            nodes[node_id]["region"] = region_id

    call_edges = []
    for edge in valid_edges:
        if _is_call(edge["relation"]):
            call_edges.append(edge)
    if calls_path is not None:
        calls_payload = _read_json(calls_path, "call artifact")
        for edge in _edge_dicts(helper, calls_payload, "call artifact"):
            if edge["source"] in node_ids and edge["target"] in node_ids and _is_call(edge["relation"]):
                call_edges.append(edge)
    unique_calls = {}
    for edge in call_edges:
        key = (edge["source"], edge["target"], edge["relation"])
        unique_calls[key] = edge
    return GraphSnapshot(
        nodes=nodes,
        edges=valid_edges,
        calls=[unique_calls[key] for key in sorted(unique_calls)],
        max_visible=max_visible,
        source_root=source_root,
        graph_path=graph_path,
        structural_path=structural_path,
        calls_path=calls_path,
    )


class GraphSnapshot:
    def __init__(
        self,
        nodes,
        edges,
        calls,
        max_visible,
        source_root,
        graph_path,
        structural_path,
        calls_path,
    ):
        self.nodes = nodes
        self.edges = edges
        self.calls = calls
        self.max_visible = max_visible
        self.source_root = source_root
        self.graph_path = graph_path
        self.structural_path = structural_path
        self.calls_path = calls_path

    def _entities(self, level):
        grouped = defaultdict(list)
        for node_id in sorted(self.nodes):
            node = self.nodes[node_id]
            if level == "function":
                key = "function:" + node_id
            elif level == "file":
                key = "file:" + (node["module"] or node["source_path"] or node_id)
            else:
                key = node["region"]
            grouped[key].append(node_id)

        entities = {}
        for entity_id, members in sorted(grouped.items()):
            member_nodes = [self.nodes[node_id] for node_id in members]
            paths = sorted({node["source_path"] for node in member_nodes if node["source_path"]})
            if level == "region":
                label = entity_id
            elif level == "file":
                label = entity_id.split(":", 1)[1]
            else:
                label = member_nodes[0]["label"]
            entities[entity_id] = {
                "id": entity_id,
                "label": label,
                "level": level,
                "kind": member_nodes[0]["kind"] or level,
                "source_paths": paths,
                "node_ids": members,
                "member_count": len(members),
            }
        return entities

    def _entity_for_node(self, level, node_id, entities):
        if level == "function":
            return "function:" + node_id
        node = self.nodes[node_id]
        if level == "file":
            return "file:" + (node["module"] or node["source_path"] or node_id)
        return node["region"]

    def _entity_role(self, level, entity, incident_edges):
        if level == "region":
            return "structural_region"
        values = [entity["id"], entity["label"], *entity["source_paths"], entity["kind"]]
        if _has_test_marker(values):
            return "test"
        kind = entity["kind"].casefold()
        is_function = level == "function" or any(
            marker in kind for marker in ("function", "method", "callable")
        )
        if is_function and (incident_edges or kind):
            return "function"
        if not incident_edges:
            return "leaf"
        return "file_module"
    def _assign_entity_roles(self, level, entities):
        incident_edges = defaultdict(int)
        for edge in (*self.edges, *self.calls):
            source = self._entity_for_node(level, edge["source"], entities)
            target = self._entity_for_node(level, edge["target"], entities)
            incident_edges[source] += 1
            incident_edges[target] += 1
        for entity_id, entity in entities.items():
            entity["role"] = self._entity_role(
                level, entity, incident_edges[entity_id]
            )

    def _scene_call_edges(self, level, entities, region_clusters=None):
        grouped = defaultdict(int)
        relations = defaultdict(set)
        for edge in self.calls:
            if level == "cluster":
                source_region = self.nodes[edge["source"]]["region"]
                target_region = self.nodes[edge["target"]]["region"]
                source = region_clusters[source_region]
                target = region_clusters[target_region]
            else:
                source = self._entity_for_node(level, edge["source"], entities)
                target = self._entity_for_node(level, edge["target"], entities)
            if source == target:
                continue
            key = (source, target)
            grouped[key] += 1
            relations[key].add(edge["relation"])
        output = []
        for source, target in sorted(grouped):
            relation_values = sorted(relations[(source, target)])
            relation = relation_values[0] if len(relation_values) == 1 else "calls"
            output.append(
                {
                    "id": "call:{}:{}:{}".format(level, source, target),
                    "source": source,
                    "target": target,
                    "level": level,
                    "kind": "call",
                    "relation": relation,
                    "label": relation,
                    "count": grouped[(source, target)],
                }
            )
        return output

    def _region_cluster_key(self, entity):
        folders = []
        for path in entity["source_paths"]:
            parts = [
                part
                for part in str(path).replace("\\", "/").strip("/").split("/")
                if part not in ("", ".")
            ]
            if parts:
                folders.append(parts[0] if len(parts) > 1 else "(root)")
        if not folders:
            for node_id in entity["node_ids"]:
                token = str(node_id).split("_", 1)[0]
                if token:
                    folders.append(token)
        return sorted(folders)[0] if folders else "(other)"

    def _region_clusters(self, regions):
        groups = defaultdict(list)
        for region_id in sorted(regions):
            groups[self._region_cluster_key(regions[region_id])].append(region_id)
        clusters = {}
        region_clusters = {}
        for folder in sorted(groups):
            grouped = groups[folder]
            cluster_id = "cluster:folder:" + hashlib.sha256(
                folder.encode("utf-8")
            ).hexdigest()[:16]
            label = "project root" if folder == "(root)" else folder + "/"
            clusters[cluster_id] = {
                "id": cluster_id,
                "label": "{} · {} regions".format(label, len(grouped)),
                "level": "cluster",
                "role": "structural_cluster",
                "parent_id": None,
                "cluster_id": cluster_id,
                "grouping": "folder",
                "source_paths": sorted(
                    {
                        path
                        for region_id in grouped
                        for path in regions[region_id]["source_paths"]
                    }
                ),
                "node_ids": [
                    node_id
                    for region_id in grouped
                    for node_id in regions[region_id]["node_ids"]
                ],
                "member_count": len(grouped),
            }
            for region_id in grouped:
                region_clusters[region_id] = cluster_id
        return clusters, region_clusters

    def scene(self, limit):
        level_entities = {
            level: self._entities(level)
            for level in ("region", "file", "function")
        }
        for level, entities in level_entities.items():
            self._assign_entity_roles(level, entities)
        clusters, region_clusters = self._region_clusters(level_entities["region"])

        region_nodes = []
        for entity_id in sorted(level_entities["region"]):
            entity = level_entities["region"][entity_id]
            region_nodes.append(
                {
                    "id": entity_id,
                    "label": entity["label"],
                    "level": "region",
                    "role": entity["role"],
                    "parent_id": region_clusters[entity_id],
                    "cluster_id": region_clusters[entity_id],
                    "source_paths": entity["source_paths"],
                    "node_ids": entity["node_ids"],
                    "member_count": entity["member_count"],
                }
            )

        file_nodes = []
        for entity_id in sorted(level_entities["file"]):
            entity = level_entities["file"][entity_id]
            member = self.nodes[entity["node_ids"][0]]
            region_id = member["region"]
            file_nodes.append(
                {
                    "id": entity_id,
                    "label": entity["label"],
                    "level": "file",
                    "role": entity["role"],
                    "parent_id": region_id,
                    "cluster_id": region_clusters[region_id],
                    "source_paths": entity["source_paths"],
                    "node_ids": entity["node_ids"],
                    "member_count": entity["member_count"],
                }
            )

        function_nodes = []
        for entity_id in sorted(level_entities["function"]):
            entity = level_entities["function"][entity_id]
            member = self.nodes[entity["node_ids"][0]]
            region_id = member["region"]
            function_nodes.append(
                {
                    "id": entity_id,
                    "label": entity["label"],
                    "level": "function",
                    "role": entity["role"],
                    "parent_id": "file:" + (
                        member["module"] or member["source_path"] or entity["node_ids"][0]
                    ),
                    "cluster_id": region_clusters[region_id],
                    "source_paths": entity["source_paths"],
                    "node_ids": entity["node_ids"],
                    "member_count": entity["member_count"],
                }
            )

        def take_spread(nodes, budget, group_key):
            groups = defaultdict(list)
            for node in nodes:
                groups[group_key(node)].append(node)
            for grouped in groups.values():
                grouped.sort(key=lambda node: node["id"])
            selected = []
            while len(selected) < budget:
                added = False
                for group_id in sorted(groups):
                    if groups[group_id]:
                        selected.append(groups[group_id].pop(0))
                        added = True
                        if len(selected) >= budget:
                            break
                if not added:
                    break
            return selected

        cluster_nodes = [clusters[cluster_id] for cluster_id in sorted(clusters)]
        cluster_budget = min(len(cluster_nodes), limit)
        selected_clusters = cluster_nodes[:cluster_budget]
        selected_cluster_ids = {node["id"] for node in selected_clusters}
        region_budget = min(
            len(region_nodes), max(0, (limit - len(selected_clusters)) // 3)
        )
        selected_regions = take_spread(
            [
                node
                for node in region_nodes
                if node["parent_id"] in selected_cluster_ids
            ],
            region_budget,
            lambda node: node["parent_id"],
        )
        selected_region_ids = {node["id"] for node in selected_regions}
        file_budget = min(
            len(file_nodes),
            max(0, (limit - len(selected_clusters) - len(selected_regions)) // 2),
        )
        selected_files = take_spread(
            [node for node in file_nodes if node["parent_id"] in selected_region_ids],
            file_budget,
            lambda node: node["parent_id"],
        )
        selected_file_ids = {node["id"] for node in selected_files}
        function_budget = max(
            0,
            limit
            - len(selected_clusters)
            - len(selected_regions)
            - len(selected_files),
        )
        selected_functions = take_spread(
            [
                node
                for node in function_nodes
                if node["parent_id"] in selected_file_ids
            ],
            function_budget,
            lambda node: node["parent_id"],
        )
        selected_nodes = (
            selected_clusters + selected_regions + selected_files + selected_functions
        )
        selected_ids = {node["id"] for node in selected_nodes}

        edges = []
        edges.extend(self._scene_call_edges("cluster", level_entities["region"], region_clusters))
        for level in ("region", "file", "function"):
            edges.extend(self._scene_call_edges(level, level_entities[level]))
        for node in (*region_nodes, *file_nodes, *function_nodes):
            edges.append(
                {
                    "id": "contains:{}:{}".format(node["parent_id"], node["id"]),
                    "source": node["parent_id"],
                    "target": node["id"],
                    "level": node["level"],
                    "kind": "contains",
                    "relation": "contains",
                    "label": "",
                    "count": 1,
                }
            )
        selected_edges = [
            edge
            for edge in sorted(edges, key=lambda edge: edge["id"])
            if edge["source"] in selected_ids and edge["target"] in selected_ids
        ][:limit]
        all_nodes = cluster_nodes + region_nodes + file_nodes + function_nodes
        return {
            "schema": "graphify-scene/v2",
            "nodes": selected_nodes,
            "edges": selected_edges,
            "truncated": len(selected_nodes) < len(all_nodes),
            "total_nodes": len(all_nodes),
            "total_edges": len(edges),
            "max_visible": limit,
            "graph_generation": self.generation,
        }



    def subgraph(self, level, center, limit):
        entities = self._entities(level)
        self._assign_entity_roles(level, entities)
        entity_edges = defaultdict(int)
        edge_relations = defaultdict(set)
        for edge in self.calls:
            source = self._entity_for_node(level, edge["source"], entities)
            target = self._entity_for_node(level, edge["target"], entities)
            if level == "region" and source == target:
                continue
            key = (source, target)
            entity_edges[key] += 1
            edge_relations[key].add(edge["relation"])


        adjacency = defaultdict(set)
        for source, target in entity_edges:
            adjacency[source].add(target)
            adjacency[target].add(source)
        ordered_ids = sorted(entities)
        selected_ids = ordered_ids
        if center:
            center_id = center if center in entities else next(
                (
                    entity_id
                    for entity_id, entity in entities.items()
                    if center in entity["node_ids"]
                ),
                None,
            )
            if center_id:
                selected_ids = []
                seen = {center_id}
                queue = deque([center_id])
                while queue and len(selected_ids) < limit:
                    current = queue.popleft()
                    selected_ids.append(current)
                    for neighbor in sorted(adjacency[current]):
                        if neighbor not in seen:
                            seen.add(neighbor)
                            queue.append(neighbor)
                selected_ids.extend(
                    entity_id for entity_id in ordered_ids if entity_id not in seen
                )
        truncated = len(selected_ids) > limit
        selected_ids = selected_ids[:limit]
        selected = set(selected_ids)
        output_nodes = [entities[entity_id] for entity_id in selected_ids]
        output_edges = []
        for (source, target), count in sorted(entity_edges.items()):
            if source not in selected or target not in selected:
                continue
            relations = sorted(edge_relations[(source, target)])
            output_edges.append(
                {
                    "source": source,
                    "target": target,
                    "relation": relations[0] if len(relations) == 1 else "calls",
                    "label": relations[0] if len(relations) == 1 else "calls",
                    "count": count,
                }
            )
        if len(output_edges) > limit:
            output_edges = output_edges[:limit]
            truncated = True
        return {
            "schema": "graphify-view/v1",
            "level": level,
            "nodes": output_nodes,
            "edges": output_edges,
            "truncated": truncated,
            "total_nodes": len(entities),
            "total_edges": len(entity_edges),
            "graph_generation": self.generation,
        }

    def _node_role(self, node_id, node):
        values = [node_id, node["label"], node["module"], node["source_path"], node["kind"]]
        if _has_test_marker(values):
            return "test"
        kind = node["kind"].casefold()
        if any(marker in kind for marker in ("function", "method", "callable")):
            return "function"
        incident = any(
            node_id in (edge["source"], edge["target"])
            for edge in (*self.edges, *self.calls)
        )
        return "file_module" if incident else "leaf"

    def search(self, query, limit):
        needle = query.casefold().strip()
        if not needle:
            return []
        results = []
        for node_id in sorted(self.nodes):
            node = self.nodes[node_id]
            haystack = " ".join(
                (node_id, node["label"], node["source_path"], node["module"])
            ).casefold()
            if needle in haystack:
                results.append(
                    {
                        "id": node_id,
                        "label": node["label"],
                        "source_path": node["source_path"],
                        "kind": node["kind"],
                        "role": self._node_role(node_id, node),
                    }
                )
                if len(results) >= limit:
                    break
        return results

    def source(self, relative_path):
        requested = pathlib.Path(relative_path)
        if requested.is_absolute():
            candidate = requested.resolve()
        else:
            candidate = (self.source_root / requested).resolve()
        try:
            candidate.relative_to(self.source_root)
        except ValueError:
            raise CliError("source path is outside --source-root")
        try:
            data = candidate.read_bytes()
        except FileNotFoundError:
            raise CliError("source file does not exist: {}".format(relative_path))
        except OSError as exc:
            raise CliError("could not read source file: {}".format(exc))
        truncated = len(data) > MAX_SOURCE_BYTES
        text = data[:MAX_SOURCE_BYTES].decode("utf-8", errors="replace")
        return {"path": relative_path, "content": text, "truncated": truncated}


class GraphStore:
    def __init__(self, args):
        if args.max_visible < 1:
            raise CliError("--max-visible must be at least 1")
        self.graph_path = pathlib.Path(args.graph).resolve()
        self.structural_path = _discover(args.structural, DEFAULT_STRUCTURAL_CANDIDATES)
        self.calls_path = _discover(args.calls, DEFAULT_CALL_CANDIDATES)
        self.source_root = pathlib.Path(args.source_root).resolve()
        if not self.source_root.is_dir():
            raise CliError("--source-root is not a directory: {}".format(self.source_root))
        self.max_visible = args.max_visible
        self.lock = threading.RLock()
        self.snapshot = None
        self.signatures = None
        self.generation = 0
        self.reload_error = ""
        self.refresh(force=True)

    def _current_signatures(self):
        paths = [self.graph_path, self.structural_path, self.calls_path]
        return tuple(_signature(path) if path is not None else None for path in paths)

    def refresh(self, force=False):
        with self.lock:
            signatures = self._current_signatures()
            if not force and signatures == self.signatures:
                return
            try:
                snapshot = _load_snapshot(
                    self.graph_path,
                    self.structural_path,
                    self.calls_path,
                    self.max_visible,
                    self.source_root,
                )
            except CliError as exc:
                self.reload_error = str(exc)
                if force:
                    raise
                return
            self.generation += 1
            snapshot.generation = self.generation
            self.snapshot = snapshot
            self.signatures = signatures
            self.reload_error = ""

    def require_snapshot(self):
        self.refresh()
        with self.lock:
            if self.reload_error:
                raise CliError("derived graph reload failed: {}".format(self.reload_error))
            return self.snapshot

    def health(self):
        snapshot = self.require_snapshot()
        return {
            "schema": "graphify-view/v1",
            "generation": snapshot.generation,
            "nodes": len(snapshot.nodes),
            "call_edges": len(snapshot.calls),
            "reload_error": self.reload_error,
            "artifacts": {
                "graph": str(self.graph_path),
                "structural": str(self.structural_path) if self.structural_path else None,
                "calls": str(self.calls_path) if self.calls_path else None,
            },
        }




class Handler(BaseHTTPRequestHandler):
    store = None
    frontend_root = None

    def _send_json(self, status, value):
        body = json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_frontend(self, route):
        relative = urllib.parse.unquote(route.lstrip("/")) or "index.html"
        candidate = (self.frontend_root / relative).resolve()
        try:
            candidate.relative_to(self.frontend_root)
        except ValueError:
            self._send_json(400, {"error": "frontend path is outside the viewer assets"})
            return
        if not candidate.is_file():
            self._send_json(404, {"error": "viewer asset not found"})
            return
        try:
            body = candidate.read_bytes()
        except OSError as exc:
            raise CliError("could not read viewer asset: {}".format(exc))
        content_type = mimetypes.guess_type(str(candidate))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _query(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def _limit(self, query):
        value = query.get("limit", [str(self.store.max_visible)])[0]
        try:
            value = int(value)
        except ValueError:
            raise CliError("limit must be an integer")
        if value < 1:
            raise CliError("limit must be at least 1")
        return min(value, self.store.max_visible)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        route = urllib.parse.urlsplit(self.path).path
        try:
            if route == "/" or not route.startswith("/api/"):
                return self._send_frontend(route)
            query = self._query()
            snapshot = self.store.require_snapshot()
            if route == "/api/health":
                return self._send_json(200, self.store.health())
            if route == "/api/scene":
                return self._send_json(200, snapshot.scene(self._limit(query)))
            if route in ("/api/graph", "/api/subgraph"):
                level = query.get("level", [""])[0].lower()
                if level in ("low", "overview"):
                    level = "region"
                elif level in ("mid", "module", "files"):
                    level = "file"
                elif level in ("high", "detail", "functions"):
                    level = "function"
                if not level:
                    try:
                        zoom = float(query.get("zoom", ["0.2"])[0])
                    except ValueError:
                        raise CliError("zoom must be a number between 0 and 1")
                    if not 0 <= zoom <= 1:
                        raise CliError("zoom must be a number between 0 and 1")
                    level = "region" if zoom < 0.34 else ("file" if zoom < 0.67 else "function")
                if level not in ("region", "file", "function"):
                    raise CliError("level must be region, file, or function")
                center = query.get("center", [""])[0]
                return self._send_json(200, snapshot.subgraph(level, center, self._limit(query)))
            if route == "/api/search":
                return self._send_json(200, snapshot.search(query.get("q", [""])[0], self._limit(query)))
            if route == "/api/source":
                path = query.get("path", [""])[0]
                if not path:
                    raise CliError("source path is required")
                return self._send_json(200, snapshot.source(path))
            self._send_json(404, {"error": "not found"})
        except CliError as exc:
            self._send_json(503 if "reload" in str(exc) else 400, {"error": str(exc)})
        except (BrokenPipeError, ConnectionResetError):
            return

    def log_message(self, _format, *_args):
        return


def main(argv=None):
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        if not 0 <= args.port <= 65535:
            raise CliError("--port must be between 0 and 65535")
        frontend_root = pathlib.Path(args.frontend).resolve()
        if not (frontend_root / "index.html").is_file():
            raise CliError(
                "built Svelte viewer not found at {}; run (cd web && npm install && npm run build)".format(
                    frontend_root
                )
            )
        store = GraphStore(args)
        Handler.store = store
        Handler.frontend_root = frontend_root
        server = ThreadingHTTPServer((args.host, args.port), Handler)
        host, port = server.server_address
        print("graphify viewer listening at http://{}:{}/".format(host, port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
    except CliError as exc:
        print("fm-graphify-viewer: {}".format(exc), file=sys.stderr)
        return 2
    except OSError as exc:
        print("fm-graphify-viewer: could not bind viewer server: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
