"""Read project identity from recorded workspaces and Git administrative files."""

from functools import lru_cache
import hashlib
from pathlib import Path


def identity_id(kind, value):
    return kind + ":" + hashlib.sha256(str(value).encode()).hexdigest()[:24]


def small_text(path):
    try:
        if not path.is_file() or path.stat().st_size > 8192:
            return ""
        return path.read_text(errors="replace").strip()
    except OSError:
        return ""


@lru_cache(maxsize=10000)
def git_project(workspace):
    """Worktrees share the resolved Git common directory, never a basename."""
    if not workspace:
        return None
    try:
        current = Path(workspace).expanduser().resolve()
        if not current.is_dir():
            return None
        for directory in (current, *current.parents):
            marker = directory / ".git"
            if marker.is_dir():
                gitdir = marker.resolve()
            elif marker.is_file():
                value = small_text(marker)
                if not value.startswith("gitdir:"):
                    continue
                gitdir = (directory / value.partition(":")[2].strip()).resolve()
                if not gitdir.is_dir():
                    continue
            else:
                continue
            common = small_text(gitdir / "commondir")
            common = (gitdir / common).resolve() if common else gitdir
            if not common.is_dir():
                return None
            root = common.parent if common.name == ".git" else directory
            return {"project_id": identity_id("git", common), "project_name": root.name,
                    "project_path": str(root), "project_identity": "Verified Git common directory: " + str(common)}
    except (OSError, RuntimeError):
        return None
    return None


def project_metadata(workspace="", *, recorded_id=None, recorded_name=None,
                     recorded_root=None, namespace=""):
    project = git_project(str(workspace or "")) or git_project(str(recorded_root or ""))
    root = str(recorded_root or workspace or "").strip()
    if not project and root:
        try:
            root = str(Path(root).expanduser().resolve())
        except (OSError, RuntimeError):
            pass
        project = {"project_id": identity_id("path", root),
                   "project_name": Path(root).name or root, "project_path": root,
                   "project_identity": "Exact recorded workspace path"}
    if not project and recorded_id:
        project = {"project_id": identity_id("recorded", namespace + ":" + str(recorded_id)),
                   "project_name": "Unknown project", "project_path": "",
                   "project_identity": "Recorded project ID without a workspace"}
    project = dict(project or {"project_id": "unknown", "project_name": "Unknown project",
                              "project_path": "", "project_identity": "No recorded project or workspace"})
    if recorded_name:
        project["project_name"] = str(recorded_name).strip() or project["project_name"]
    if recorded_id:
        project["project_identity"] += " · recorded T3 project " + str(recorded_id)
    return project


def harmonize_recorded_workspaces(db):
    """A recorded T3 workspace-to-project link survives a deleted worktree."""
    assignments = {}
    for row in db.execute("SELECT workspace,project_id,project_name,project_path,project_identity FROM chats WHERE app='T3 Code' AND workspace<>'' AND project_identity LIKE '%recorded T3 project%' ORDER BY updated_at DESC"):
        assignments.setdefault(row["workspace"], {}).setdefault(row["project_id"], dict(row))
    for workspace, candidates in assignments.items():
        if len(candidates) != 1:
            continue
        project = next(iter(candidates.values()))
        db.execute("UPDATE chats SET project_id=?,project_name=?,project_path=?,project_identity=? WHERE workspace=? AND app<>'T3 Code' AND project_identity NOT LIKE 'Verified Git common directory:%'",
                   (project["project_id"], project["project_name"], project["project_path"],
                    "Recorded T3 project for this exact workspace · " + project["project_identity"], workspace))
