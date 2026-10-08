# Adaptable templates

Use only the templates useful to the requested views.
The examples share a synthetic target model and use Mermaid; replace their domain labels and evidence rather than copying them as facts.
Validate adapted sources with the installed parser or renderer before delivery.

## Model and view records

```text
Element: id | name | C4 type | parent | responsibility | technology | owner/trust | state | evidence
Relationship: from | to | directional action | protocol | state | evidence
View: id | diagram type | scope | audience | revision/environment | question answered | limitations
```

## System context skeleton

```mermaid
---
title: C4 System Context - Example service - target
---
flowchart LR
  person["Reviewer<br/>Person<br/>Reviews a submission"]
  subgraph boundary[Example service ownership boundary]
    system["Example service<br/>Software system<br/>Stores and publishes submissions"]
  end
  external["Identity service<br/>External software system<br/>Confirms reviewer identity"]
  person -->|Submits and reviews work in| system
  system -->|Verifies reviewer with| external
  key["KEY: boxes = typed people/systems; enclosure = ownership.<br/>Arrows = labelled directional interactions; all elements are target state."]
```

## Container skeleton

```mermaid
---
title: C4 Containers - Example service - target
---
flowchart LR
  person["Reviewer<br/>Person<br/>Reviews a submission"]
  subgraph system[Example service software-system boundary]
    ui["Review UI<br/>Container: browser JavaScript<br/>Displays and submits review"]
    api["Review API<br/>Container: Node.js<br/>Validates and records decisions"]
    db[("Decision database<br/>Container: PostgreSQL<br/>Durable decisions")]
  end
  external["Identity service<br/>External software system<br/>Confirms reviewer identity"]
  person -->|Operates review interface; browser input| ui
  ui -->|Reads and submits decisions; HTTPS JSON| api
  api -->|Reads and commits decisions; PostgreSQL protocol| db
  api -->|Verifies reviewer identity; HTTPS JSON| external
  key["KEY: boxes = typed people/applications/systems; cylinder = data store.<br/>Arrows = labelled directional interactions.<br/>Enclosure = logical ownership, not deployment; all elements are target state.<br/>API = application programming interface; UI = user interface.<br/>HTTPS = encrypted HTTP; JSON = JavaScript Object Notation."]
```

## Component view adaptation

Expand only `Review API` from the container skeleton.
Example components: `Request adapter [Component: Node.js]`, `Decision service [Component: TypeScript]`, and `Decision repository [Component: TypeScript / SQL]`.
Keep `Review UI` and `Decision database` as supporting containers, and `Identity service` as an external system, outside that API boundary.
Label internal calls as function calls and the repository-to-database relationship as PostgreSQL protocol.
The request adapter verifies reviewer identity with `Identity service` over HTTPS JSON.
Do not expand the database into tables in the same view.

## Deployment record template

```text
Environment: name and current/target status
Node: execution environment/host/network
Instance: model container ID + pinned revision/config reference
Connection: source instance -> destination instance, protocol and private/public boundary
Key: node nesting, instances, infrastructure nodes and line meanings
Evidence: observed runtime receipt or explicit proposed topology
```

## Dynamic record template

```text
Scenario: concrete user action and result
Level: system OR container OR component scope
Participants: existing static-model IDs
Sequence: numbered caller -> receiver: action [protocol]
Atomic region: named transaction/lock owner
Failure/retry: observable refusal, idempotency or recovery behavior
Key: boundary boxes, call/reply arrows, ordering and state
Evidence: source path/revision or runtime receipt
```
