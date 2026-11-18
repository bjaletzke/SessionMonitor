"""Project and conversation summaries from measured, selected chat records."""

from collections import defaultdict
from statistics import median


def known_sum(chats, field):
    values = [chat[field] for chat in chats if chat.get(field) is not None]
    return sum(values) if values else None


def message_average(chats, role):
    measured = [chat for chat in chats if chat.get(f"{role}_messages") is not None
                and chat.get(f"{role}_characters") is not None]
    count = sum(chat[f"{role}_messages"] for chat in measured)
    return sum(chat[f"{role}_characters"] for chat in measured) / count if count else None


def conversation_summary(chats):
    measured = [chat for chat in chats if chat.get("total_messages") is not None]
    count = len(measured)
    messages = known_sum(measured, "total_messages")
    user = known_sum(measured, "user_messages")
    assistant = known_sum(measured, "assistant_messages")
    return {
        "selected_chats": len(chats), "measured_chats": count,
        "partial_chats": sum(bool(chat.get("stats_partial")) for chat in measured),
        "unknown_chats": len(chats) - count,
        "user_messages": user, "assistant_messages": assistant,
        "total_messages": messages,
        "avg_messages_per_conversation": messages / count if count else None,
        "avg_user_messages_per_conversation": user / count if count and user is not None else None,
        "avg_response_characters": message_average(measured, "assistant"),
        "avg_prompt_characters": message_average(measured, "user"),
        "median_messages_per_conversation": median(chat["total_messages"] for chat in measured) if count else None,
        # Only per-chat sums are retained. A median across individual responses
        # cannot be recovered from those sums and is deliberately not invented.
        "median_response_characters": None,
    }


def build_insights(chats):
    grouped = defaultdict(list)
    for chat in chats:
        grouped[chat.get("project_id") or "unknown"].append(chat)
    projects = []
    for identity, members in grouped.items():
        exemplar = next((chat for chat in members if chat.get("project_name")), members[0])
        stats = conversation_summary(members)
        projects.append({
            "id": identity, "name": exemplar.get("project_name") or "Unknown project",
            "path": exemplar.get("project_path") or exemplar.get("workspace") or "",
            "paths": sorted({chat.get("project_path") or chat.get("workspace") for chat in members
                             if chat.get("project_path") or chat.get("workspace")}),
            "identity": exemplar.get("project_identity") or "No recorded project identity",
            "chats": len(members), "total_tokens": known_sum(members, "total_tokens"),
            "user_messages": stats["user_messages"], "assistant_messages": stats["assistant_messages"],
            "total_messages": stats["total_messages"],
            "measured_chats": stats["measured_chats"], "partial_chats": stats["partial_chats"],
            "avg_messages_per_conversation": stats["avg_messages_per_conversation"],
            "avg_response_characters": stats["avg_response_characters"],
            "models": sorted({chat["model"] for chat in members if chat.get("model")}),
            "harnesses": sorted({chat.get("app") or chat["connection_id"] for chat in members}),
        })
    return {"projects": sorted(projects, key=lambda project: (-project["chats"], project["name"])),
            "metrics": conversation_summary(chats)}
