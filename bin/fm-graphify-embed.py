#!/usr/bin/env python3
"""Enrich a Graphify JSON graph with deterministic semantic relationships.

The command fingerprints each node from graph-owned fields, sends those
fingerprints to an explicitly configured OpenAI-compatible embeddings endpoint,
then writes a copy of the graph with semantic cluster ids and bounded
``semantically_similar_to`` edges plus a deterministic region plan.  The input
file is never modified.

Credentials are read from the environment named by ``--api-key-env`` and are
never accepted as an argv value or included in diagnostics.  The default input
is ``graphify-out/graph.json``.  See ``docs/graphify-embeddings.md`` for the
operator contract and Graphify field compatibility details.
"""

import argparse
import copy
import hashlib
import json
import math
import os
import pathlib
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_INPUT = "graphify-out/graph.json"
DEFAULT_API_KEY_ENV = "OPENAI_API_KEY"
DEFAULT_ENDPOINT_ENV = "GRAPHIFY_EMBEDDINGS_ENDPOINT"
DEFAULT_MODEL_ENV = "GRAPHIFY_EMBEDDINGS_MODEL"
EMBEDDING_BATCH_SIZE = 64
NEIGHBOR_LIMIT = 12
REPRESENTATIVE_LIMIT = 3
SEMANTIC_EDGE_TYPE = "semantically_similar_to"


class CliError(Exception):
    """A user-actionable input, provider, or output error."""


class NodeRecord:
    """A normalized node while retaining the source graph's representation."""

    def __init__(self, node_id, node, container_key=None):
        self.node_id = node_id
        self.node = node
        self.container_key = container_key
        self.label = ""
        self.source_path = ""
        self.relations = set()
        self.neighbors = []


class UnionFind:
    """Deterministic connected components for the threshold graph."""

    def __init__(self, size):
        self.parent = list(range(size))
        self.rank = [0] * size

    def find(self, item):
        while self.parent[item] != item:
            self.parent[item] = self.parent[self.parent[item]]
            item = self.parent[item]
        return item

    def union(self, left, right):
        left_root = self.find(left)
        right_root = self.find(right)
        if left_root == right_root:
            return
        if self.rank[left_root] < self.rank[right_root]:
            left_root, right_root = right_root, left_root
        self.parent[right_root] = left_root
        if self.rank[left_root] == self.rank[right_root]:
            self.rank[left_root] += 1


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=(
            "Plan structural AST regions or embed graphify-out/graph.json "
            "fingerprints with an OpenAI-compatible backend."
        )
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        metavar="PATH",
        help="Graphify JSON input (default: graphify-out/graph.json).",
    )
    parser.add_argument(
        "--output",
        required=True,
        metavar="PATH",
        help="Output JSON path; the input graph is never changed.",
    )
    parser.add_argument(
        "--region-plan-output",
        default=None,
        metavar="PATH",
        help=(
            "Deterministic Luna/Jev region-plan JSON path; by default, write "
            "beside --output with a .regions suffix."
        ),
    )
    parser.add_argument(
        "--backend",
        choices=("openai", "local", "structural"),
        default="openai",
        help="Embedding or region backend (default: openai).",
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        metavar="URL",
        help=(
            "OpenAI-compatible embeddings endpoint; otherwise read "
            "GRAPHIFY_EMBEDDINGS_ENDPOINT."
        ),
    )
    parser.add_argument(
        "--model",
        default=None,
        metavar="MODEL",
        help=(
            "Embedding model name; otherwise read GRAPHIFY_EMBEDDINGS_MODEL."
        ),
    )
    parser.add_argument(
        "--device",
        default="cuda",
        metavar="DEVICE",
        help="Local sentence-transformers device (default: cuda).",
    )
    parser.add_argument(
        "--threshold",
        required=True,
        type=float,
        metavar="0..1",
        help="Inclusive cosine-similarity threshold for semantic edges.",
    )
    parser.add_argument(
        "--top-k",
        required=True,
        type=int,
        metavar="N",
        help="Maximum semantic edges emitted from each node.",
    )
    parser.add_argument(
        "--api-key-env",
        default=DEFAULT_API_KEY_ENV,
        metavar="NAME",
        help=(
            "Environment variable holding the optional bearer token "
            "(default: OPENAI_API_KEY)."
        ),
    )
    parser.add_argument(
        "--timeout",
        default=60.0,
        type=float,
        metavar="SECONDS",
        help="HTTP timeout per embeddings request (default: 60).",
    )
    return parser.parse_args(argv)


def configured_provider_value(argument, environment_name, label):
    value = argument or os.environ.get(environment_name, "")
    if value:
        return value
    raise CliError(
        "no embedding provider configured: pass --{} or set {}; "
        "keep any API credential in an environment variable, not argv".format(
            label, environment_name
        )
    )


def scalar_text(value):
    """Return a stable text form for a scalar or structured graph field."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise CliError("graph field is not JSON-serializable: {}".format(exc))


def first_field(node, names):
    for name in names:
        if name in node and node[name] is not None:
            text = scalar_text(node[name]).strip()
            if text:
                return text
    return ""


def node_label(node, node_id):
    label = first_field(node, ("label", "name", "title", "type", "kind"))
    return label or node_id


def node_source_path(node):
    return first_field(
        node,
        (
            "source_path",
            "sourcePath",
            "file_path",
            "filePath",
            "path",
            "file",
            "source",
        ),
    )


def node_id_value(node, fallback=None):
    if isinstance(node, dict) and node.get("id") is not None:
        value = scalar_text(node["id"]).strip()
        if value:
            return value
    if fallback is not None:
        value = scalar_text(fallback).strip()
        if value:
            return value
    return ""


def normalize_nodes(graph):
    raw_nodes = graph.get("nodes")
    if isinstance(raw_nodes, list):
        records = []
        seen_ids = set()
        for index, node in enumerate(raw_nodes):
            if not isinstance(node, dict):
                raise CliError("graph nodes[{}] must be an object".format(index))
            node_id = node_id_value(node)
            if not node_id:
                raise CliError("graph nodes[{}] is missing a non-empty id".format(index))
            if node_id in seen_ids:
                raise CliError("graph contains duplicate node id {!r}".format(node_id))
            seen_ids.add(node_id)
            records.append(NodeRecord(node_id, node))
        return records
    if isinstance(raw_nodes, dict):
        records = []
        seen_ids = set()
        for container_key, node in raw_nodes.items():
            if not isinstance(node, dict):
                raise CliError("graph nodes[{}] must be an object".format(container_key))
            node_id = node_id_value(node, container_key)
            if not node_id:
                raise CliError("graph node key {!r} is empty".format(container_key))
            if node_id in seen_ids:
                raise CliError("graph contains duplicate node id {!r}".format(node_id))
            seen_ids.add(node_id)
            records.append(NodeRecord(node_id, node, container_key))
        return records
    raise CliError("graph must contain a nodes array or object")


def edge_endpoint(edge, names):
    for name in names:
        if name in edge and edge[name] is not None:
            value = scalar_text(edge[name]).strip()
            if value:
                return value
    return ""


def edge_relation(edge):
    relation = first_field(edge, ("relation", "type", "kind", "label", "edge_type"))
    return relation or "unknown"


def normalize_edges(graph):
    if "edges" in graph:
        key = "edges"
    elif "links" in graph:
        key = "links"
    else:
        return "edges", []
    raw_edges = graph[key]
    if not isinstance(raw_edges, list):
        raise CliError("graph {} must be an array".format(key))
    edges = []
    for index, edge in enumerate(raw_edges):
        if not isinstance(edge, dict):
            raise CliError("graph {}[{}] must be an object".format(key, index))
        source = edge_endpoint(edge, ("source", "from", "src", "source_id"))
        target = edge_endpoint(edge, ("target", "to", "dst", "target_id"))
        if not source or not target:
            raise CliError("graph {}[{}] needs source and target ids".format(key, index))
        edges.append((edge, source, target, edge_relation(edge)))
    return key, edges


def connected_graph_edges(records, graph_edges):
    node_ids = {record.node_id for record in records}
    return [
        edge_info
        for edge_info in graph_edges
        if edge_info[1] in node_ids and edge_info[2] in node_ids
    ]


def build_fingerprints(records, graph_edges):
    by_id = {record.node_id: record for record in records}
    for record in records:
        record.label = node_label(record.node, record.node_id)
        record.source_path = node_source_path(record.node)

    for _edge, source, target, relation in graph_edges:
        if source not in by_id or target not in by_id:
            raise CliError(
                "graph edge refers to unknown node id {!r} or {!r}".format(source, target)
            )
        source_record = by_id[source]
        target_record = by_id[target]
        source_record.relations.add(relation)
        target_record.relations.add(relation)
        source_record.neighbors.append(
            {"direction": "out", "label": target_record.label, "relation": relation}
        )
        target_record.neighbors.append(
            {"direction": "in", "label": source_record.label, "relation": relation}
        )

    fingerprints = []
    for record in records:
        neighbors = sorted(
            record.neighbors,
            key=lambda item: (item["direction"], item["relation"], item["label"]),
        )[:NEIGHBOR_LIMIT]
        fingerprints.append(
            json.dumps(
                {
                    "label": record.label,
                    "source_path": record.source_path,
                    "relation_types": sorted(record.relations),
                    "neighbor_labels": neighbors,
                },
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    return fingerprints


def embedding_url(endpoint):
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise CliError("embedding endpoint must be an absolute http(s) URL")
    path = parsed.path.rstrip("/")
    if not path.endswith("/embeddings"):
        path += "/embeddings"
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, path, parsed.query, parsed.fragment)
    )


def decode_embeddings(payload, expected_count):
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise CliError("embedding provider response must contain a data array")
    data = payload["data"]
    if len(data) != expected_count:
        raise CliError(
            "embedding provider returned {} vectors for {} inputs".format(
                len(data), expected_count
            )
        )
    vectors = [None] * expected_count
    for position, item in enumerate(data):
        if not isinstance(item, dict) or not isinstance(item.get("embedding"), list):
            raise CliError("embedding provider returned a malformed vector at index {}".format(position))
        raw_index = item.get("index", position)
        if isinstance(raw_index, bool) or not isinstance(raw_index, int) or not 0 <= raw_index < expected_count:
            raise CliError("embedding provider returned an invalid vector index")
        if vectors[raw_index] is not None:
            raise CliError("embedding provider returned duplicate vector indices")
        vector = []
        for component in item["embedding"]:
            if isinstance(component, bool) or not isinstance(component, (int, float)):
                raise CliError("embedding provider returned a non-numeric vector component")
            number = float(component)
            if not math.isfinite(number):
                raise CliError("embedding provider returned a non-finite vector component")
            vector.append(number)
        if not vector:
            raise CliError("embedding provider returned an empty vector")
        vectors[raw_index] = vector
    if any(vector is None for vector in vectors):
        raise CliError("embedding provider response omitted a vector index")
    dimension = len(vectors[0])
    if any(len(vector) != dimension for vector in vectors):
        raise CliError("embedding provider returned vectors with different dimensions")
    return vectors


def request_embeddings(url, model, fingerprints, api_key, timeout):
    vectors = []
    for start in range(0, len(fingerprints), EMBEDDING_BATCH_SIZE):
        batch = fingerprints[start : start + EMBEDDING_BATCH_SIZE]
        body = json.dumps(
            {"input": batch, "model": model},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                response_body = response.read()
        except urllib.error.HTTPError as exc:
            raise CliError("embedding provider returned HTTP {}".format(exc.code))
        except (urllib.error.URLError, TimeoutError, OSError):
            raise CliError("could not reach the configured embedding provider")
        try:
            payload = json.loads(response_body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise CliError("embedding provider returned invalid JSON: {}".format(exc))
        vectors.extend(decode_embeddings(payload, len(batch)))
    return vectors


def decode_local_embeddings(encoded, expected_count):
    if hasattr(encoded, "tolist"):
        encoded = encoded.tolist()
    if not isinstance(encoded, (list, tuple)):
        raise CliError("local embedding model returned a non-array result")
    if len(encoded) != expected_count:
        raise CliError(
            "local embedding model returned {} vectors for {} inputs".format(
                len(encoded), expected_count
            )
        )
    vectors = []
    for position, raw_vector in enumerate(encoded):
        if not isinstance(raw_vector, (list, tuple)):
            raise CliError(
                "local embedding model returned a malformed vector at index {}".format(
                    position
                )
            )
        vector = []
        for component in raw_vector:
            if isinstance(component, bool) or not isinstance(component, (int, float)):
                raise CliError(
                    "local embedding model returned a non-numeric vector component"
                )
            number = float(component)
            if not math.isfinite(number):
                raise CliError(
                    "local embedding model returned a non-finite vector component"
                )
            vector.append(number)
        if not vector:
            raise CliError("local embedding model returned an empty vector")
        vectors.append(vector)
    dimension = len(vectors[0])
    if any(len(vector) != dimension for vector in vectors):
        raise CliError(
            "local embedding model returned vectors with different dimensions"
        )
    return vectors


def request_local_embeddings(model, fingerprints, device):
    if device.startswith("cuda"):
        try:
            import torch
        except ImportError:
            raise CliError(
                "CUDA device requested but PyTorch is unavailable; install "
                "PyTorch with CUDA support"
            )
        try:
            cuda_available = bool(torch.cuda.is_available())
        except Exception as exc:
            raise CliError(
                "could not determine CUDA availability: {}".format(
                    type(exc).__name__
                )
            )
        if not cuda_available:
            raise CliError(
                "CUDA device requested but CUDA is unavailable; choose an "
                "explicit non-CUDA --device or install a CUDA-enabled PyTorch"
            )
    if not fingerprints:
        return []
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        raise CliError(
            "local embedding backend requires sentence-transformers and "
            "PyTorch; install both before using --backend local"
        )
    try:
        encoder = SentenceTransformer(model, device=device)
    except Exception as exc:
        raise CliError(
            "could not load local embedding model: {}".format(type(exc).__name__)
        )
    if device.startswith("cuda"):
        actual_device = str(getattr(encoder, "device", ""))
        if not actual_device.startswith("cuda"):
            raise CliError(
                "local embedding model did not use the requested CUDA device"
            )
    try:
        encoded = encoder.encode(
            fingerprints,
            convert_to_numpy=True,
            show_progress_bar=False,
        )
    except Exception as exc:
        raise CliError(
            "local embedding model failed to encode graph fingerprints: {}".format(
                type(exc).__name__
            )
        )
    return decode_local_embeddings(encoded, len(fingerprints))


def cosine(left, right):
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        raise CliError("embedding provider returned a zero vector")
    return sum(a * b for a, b in zip(left, right)) / (left_norm * right_norm)


def semantic_relationships(records, vectors, threshold, top_k):
    similarities = []
    for index, vector in enumerate(vectors):
        row = []
        for other_index, other_vector in enumerate(vectors):
            if index == other_index:
                continue
            score = cosine(vector, other_vector)
            if score >= threshold:
                row.append((score, other_index))
        row.sort(key=lambda item: (-item[0], records[item[1]].node_id))
        similarities.append(row[:top_k])

    union_find = UnionFind(len(records))
    edges = []
    for source_index, row in enumerate(similarities):
        for score, target_index in row:
            union_find.union(source_index, target_index)
            edges.append(
                {
                    "source": records[source_index].node_id,
                    "target": records[target_index].node_id,
                    "type": SEMANTIC_EDGE_TYPE,
                    "relation": SEMANTIC_EDGE_TYPE,
                    "similarity": score,
                }
            )
    edges.sort(key=lambda edge: (edge["source"], edge["target"]))

    groups = {}
    for index, record in enumerate(records):
        groups.setdefault(union_find.find(index), []).append(record.node_id)
    cluster_ids = {}
    for members in groups.values():
        members.sort()
        digest_input = "\0".join(members).encode("utf-8")
        cluster_id = "semantic-cluster-" + hashlib.sha256(digest_input).hexdigest()[:16]
        for member in members:
            cluster_ids[member] = cluster_id
    return cluster_ids, edges


def structural_regions(records, graph_edges):
    node_indices = {record.node_id: index for index, record in enumerate(records)}
    union_find = UnionFind(len(records))
    for _edge, source, target, relation in graph_edges:
        if relation != SEMANTIC_EDGE_TYPE:
            union_find.union(node_indices[source], node_indices[target])

    groups = {}
    for index, record in enumerate(records):
        groups.setdefault(union_find.find(index), []).append(record.node_id)
    region_ids = {}
    for members in groups.values():
        members.sort()
        digest_input = "\0".join(members).encode("utf-8")
        region_id = "structural-region-" + hashlib.sha256(digest_input).hexdigest()[:16]
        for member in members:
            region_ids[member] = region_id
    return region_ids

def region_node_snapshot(record):
    neighbors = sorted(
        record.neighbors,
        key=lambda item: (
            item["direction"],
            item["relation"],
            item["label"],
        ),
    )[:NEIGHBOR_LIMIT]
    return {
        "node_id": record.node_id,
        "label": record.label,
        "source_path": record.source_path,
        "relation_types": sorted(record.relations),
        "neighbors": neighbors,
    }

def build_region_plan(records, graph_edges, cluster_ids, strategy):
    by_id = {record.node_id: record for record in records}
    members_by_cluster = {}
    for record in records:
        members_by_cluster.setdefault(cluster_ids[record.node_id], []).append(record.node_id)
    relation_counts = {cluster_id: {} for cluster_id in members_by_cluster}
    cross_links = {}

    for _edge, source, target, relation in graph_edges:
        source_cluster = cluster_ids[source]
        target_cluster = cluster_ids[target]
        source_counts = relation_counts[source_cluster]
        source_counts[relation] = source_counts.get(relation, 0) + 1
        if target_cluster != source_cluster:
            target_counts = relation_counts[target_cluster]
            target_counts[relation] = target_counts.get(relation, 0) + 1
            key = (source_cluster, target_cluster, relation)
            link = cross_links.setdefault(
                key,
                {
                    "source_cluster_id": source_cluster,
                    "target_cluster_id": target_cluster,
                    "relation": relation,
                    "edge_count": 0,
                    "examples": [],
                },
            )
            link["edge_count"] += 1
            link["examples"].append(
                {"source_node_id": source, "target_node_id": target}
            )

    clusters = []
    for cluster_id in sorted(members_by_cluster):
        member_ids = sorted(members_by_cluster[cluster_id])
        representatives = sorted(
            member_ids,
            key=lambda node_id: (-len(by_id[node_id].neighbors), node_id),
        )[:REPRESENTATIVE_LIMIT]
        source_paths = sorted(
            {
                by_id[node_id].source_path
                for node_id in member_ids
                if by_id[node_id].source_path
            }
        )
        relation_summary = [
            {"relation": relation, "edge_count": count}
            for relation, count in sorted(relation_counts[cluster_id].items())
        ]
        clusters.append(
            {
                "cluster_id": cluster_id,
                "node_count": len(member_ids),
                "node_ids": member_ids,
                "source_paths": source_paths,
                "relation_summary": relation_summary,
                "representative_nodes": [
                    region_node_snapshot(by_id[node_id]) for node_id in representatives
                ],
            }
        )

    links = []
    for key in sorted(cross_links):
        link = cross_links[key]
        link["examples"].sort(
            key=lambda item: (item["source_node_id"], item["target_node_id"])
        )
        link["examples"] = link["examples"][:REPRESENTATIVE_LIMIT]
        links.append(link)
    return {
        "schema": "graphify-region-plan/v1",
        "strategy": strategy,
        "clusters": clusters,
        "cross_region_links": links,
    }


def default_region_plan_path(output_path):
    destination = pathlib.Path(output_path)
    if destination.suffix:
        return str(destination.with_name(destination.stem + ".regions" + destination.suffix))
    return str(destination) + ".regions.json"


def enrich_graph(
    graph, records, cluster_ids, semantic_edges, edge_key, cluster_field
):
    output = copy.deepcopy(graph)
    raw_nodes = output["nodes"]
    if any(cluster_field in record.node for record in records):
        cluster_field = "graphify_" + cluster_field
    if isinstance(raw_nodes, list):
        for index, record in enumerate(records):
            raw_nodes[index][cluster_field] = cluster_ids[record.node_id]
    else:
        for record in records:
            raw_nodes[record.container_key][cluster_field] = cluster_ids[record.node_id]

    output_edges = output.setdefault(edge_key, [])
    output_edges.extend(semantic_edges)
    return output


def write_json(path, value, description):
    destination = pathlib.Path(path)
    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=str(parent), prefix=".graphify-embed-", delete=False
        ) as temporary:
            temporary_name = temporary.name
            json.dump(value, temporary, ensure_ascii=False, indent=2, sort_keys=True)
            temporary.write("\n")
        os.replace(temporary_name, destination)
    except (OSError, TypeError, ValueError) as exc:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise CliError("could not write {}: {}".format(description, exc))


def run(args):
    if not 0 <= args.threshold <= 1:
        raise CliError("--threshold must be between 0 and 1")
    if args.top_k < 1:
        raise CliError("--top-k must be at least 1")
    if args.timeout <= 0:
        raise CliError("--timeout must be greater than 0")

    url = None
    api_key = ""
    model = None
    if args.backend == "openai":
        endpoint = configured_provider_value(
            args.endpoint, DEFAULT_ENDPOINT_ENV, "endpoint"
        )
        url = embedding_url(endpoint)
        api_key = os.environ.get(args.api_key_env, "")
        model = configured_provider_value(args.model, DEFAULT_MODEL_ENV, "model")
    elif args.backend == "local":
        model = configured_provider_value(args.model, DEFAULT_MODEL_ENV, "model")

    input_path = pathlib.Path(args.input)
    output_path = pathlib.Path(args.output)
    region_plan_path = pathlib.Path(
        args.region_plan_output or default_region_plan_path(args.output)
    )
    resolved_input = input_path.resolve()
    if output_path.resolve() == resolved_input:
        raise CliError("output path must differ from the input graph")
    if region_plan_path.resolve() == resolved_input:
        raise CliError("region-plan output path must differ from the input graph")
    if region_plan_path.resolve() == output_path.resolve():
        raise CliError("region-plan output path must differ from --output")

    try:
        with input_path.open("r", encoding="utf-8") as stream:
            graph = json.load(stream)
    except FileNotFoundError:
        raise CliError("input graph does not exist: {}".format(input_path))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise CliError("could not read input graph: {}".format(exc))
    if not isinstance(graph, dict):
        raise CliError("input graph must be a JSON object")

    records = normalize_nodes(graph)
    edge_key, graph_edges = normalize_edges(graph)
    connected_edges = connected_graph_edges(records, graph_edges)
    region_edges = [
        edge_info
        for edge_info in connected_edges
        if edge_info[3] != SEMANTIC_EDGE_TYPE
    ]
    fingerprints = build_fingerprints(records, region_edges)
    if args.backend == "structural":
        cluster_ids = structural_regions(records, region_edges)
        semantic_edges = []
        strategy = "structural_ast"
        cluster_field = "structural_region_id"
    else:
        vectors = (
            request_local_embeddings(model, fingerprints, args.device)
            if args.backend == "local"
            else request_embeddings(url, model, fingerprints, api_key, args.timeout)
        )
        cluster_ids, semantic_edges = semantic_relationships(
            records, vectors, args.threshold, args.top_k
        )
        strategy = "embedding"
        cluster_field = "semantic_cluster_id"
    region_plan = build_region_plan(records, region_edges, cluster_ids, strategy)
    output = enrich_graph(
        graph, records, cluster_ids, semantic_edges, edge_key, cluster_field
    )
    write_json(args.output, output, "output graph")
    write_json(region_plan_path, region_plan, "region plan")
    if args.backend == "structural":
        print(
            "graphify structural region plan complete: {} nodes, {} regions, "
            "output {}, region plan {}".format(
                len(records),
                len(set(cluster_ids.values())),
                args.output,
                region_plan_path,
            )
        )
    else:
        print(
            "graphify embedding complete: {} nodes, {} semantic edges, output {}, "
            "region plan {}".format(
                len(records), len(semantic_edges), args.output, region_plan_path
            )
        )


def main(argv=None):
    try:
        run(parse_args(sys.argv[1:] if argv is None else argv))
    except CliError as exc:
        print("fm-graphify-embed: {}".format(exc), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("fm-graphify-embed: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
