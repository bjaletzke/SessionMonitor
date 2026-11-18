"""Shared selection for every analytics view and SQL query."""

from datetime import datetime, timedelta, timezone


def normalize_filters(value=None):
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise ValueError("Filters must be an object")
    result = {}
    for field, default in (("connection", "all"), ("model", ""), ("provider", ""), ("project", ""), ("q", "")):
        item = value.get(field, default)
        if not isinstance(item, str) or len(item) > 500:
            raise ValueError(f"Invalid {field} filter")
        result[field] = item.strip()
    days = value.get("days", 30)
    if type(days) is not int or not 0 <= days <= 36600:
        raise ValueError("Date range must be 0–36600 days")
    result["days"] = days
    for field, default in (("include_subagents", False), ("merge_copies", True)):
        if type(value.get(field, default)) is not bool:
            raise ValueError(f"Invalid {field} filter")
        result[field] = value.get(field, default)
    return result


def select_chats(chats, relationships, filters, text_matches=(), now=None):
    now = now or datetime.now(timezone.utc)
    start = (now.replace(hour=0, minute=0, second=0, microsecond=0)
             - timedelta(days=filters["days"] - 1)).isoformat().replace("+00:00", "Z") if filters["days"] else None
    by_id = {chat["id"]: chat for chat in chats}
    roots = {cid: cid for cid in by_id}

    def root(cid):
        while roots[cid] != cid:
            roots[cid] = roots[roots[cid]]
            cid = roots[cid]
        return cid

    def join(left, right):
        if left in roots and right in roots:
            roots[root(right)] = root(left)

    if filters["merge_copies"]:
        owners = {}
        for relation in relationships:
            if relation["kind"] == "provider session":
                owners.setdefault(relation["target_id"], set()).add(relation["source_id"])
        for native, hosts in owners.items():
            if len(hosts) == 1:
                join(next(iter(hosts)), native)
        for cid in roots:
            if cid.startswith("snapshot-"):
                original = cid.partition(":")[2]
                join(original, cid)

    q = filters["q"].lower()
    matches = set(text_matches)
    candidates = []
    for chat in chats:
        if filters["connection"] != "all" and chat["connection_id"] != filters["connection"]:
            continue
        if filters["project"] and (chat.get("project_id") or "unknown") != filters["project"]:
            continue
        if not filters["include_subagents"] and chat["is_subagent"]:
            continue
        if start and (not chat["updated_at"] or chat["updated_at"] < start):
            continue
        if any(filters[field] and (chat.get(field) or "__unknown__") != filters[field] for field in ("model", "provider")):
            continue
        if q and chat["id"] not in matches and not any(q in str(chat.get(field) or "").lower() for field in ("title", "model", "provider", "workspace", "project_name", "project_path")):
            continue
        candidates.append(chat)

    def preference(chat):
        # Use measured T3 hosts first. Native counters remain available when
        # their host has no usage. Never combine the two counter totals.
        return (chat["total_tokens"] is None,
                chat["connection_id"].startswith("snapshot-"),
                chat["app"] != "T3 Code", chat["id"])

    groups = {}
    for chat in candidates:
        group = root(chat["id"])
        if group not in groups or preference(chat) < preference(groups[group]):
            groups[group] = chat
    selected = list(groups.values())
    # Preserve selected explicit edges, remapping grouped copies to the visible
    # record. Unloaded endpoints remain identifiers, never inferred edges.
    representatives = {root(c["id"]): c["id"] for c in selected}
    visible = {c["id"] for c in selected}
    edges = set()
    for relation in relationships:
        ends = [representatives.get(root(cid), cid) if cid in roots else cid
                for cid in (relation["source_id"], relation["target_id"])]
        if ends[0] != ends[1] and any(cid in visible for cid in ends):
            edges.add((*ends, relation["kind"]))
    return {
        "chats": selected,
        "relationships": [dict(zip(("source_id", "target_id", "kind"), edge)) for edge in sorted(edges)],
        "start": start,
        "summary": {"matching_records": len(candidates), "selected_chats": len(selected),
                    "grouped_records": len(candidates) - len(selected)},
    }
