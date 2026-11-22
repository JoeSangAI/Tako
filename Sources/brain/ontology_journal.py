"""Adapt Tako's old journal and trace checkpoints to the bundled engine."""
import hashlib
import json
import os
from tempfile import NamedTemporaryFile

from vendor.ontology_engine import ontology as engine


def legacy_records(path):
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue  # The old append format could leave a partial line.
        if isinstance(row, dict):
            if row.get("op") == "batch" and isinstance(row.get("rows"), list):
                rows.extend(entry for entry in row["rows"] if isinstance(entry, dict))
            else:
                rows.append(row)
    return rows


def journal_fields(fields):
    fields = {key: value for key, value in fields.items() if key not in engine.RESERVED | {"sources"}}
    if isinstance(fields.get("home"), str):
        home = fields["home"].strip()
        fields["home"] = [home] if home else []
    return fields


def convert_legacy(rows, path):
    """Translate historical decisions, keeping the original file as their trace."""
    converted, known, retired = [], {}, {}
    ordered = sorted(enumerate(rows, 1), key=lambda pair: pair[1].get("event_at", pair[1].get("at", 0)))
    for index, old in ordered:
        identity, kind, op = old.get("id"), old.get("kind"), old.get("op")
        if kind not in ("subject", "project") or not engine.name(identity):
            continue  # Inferred actions were never promises. Explicit promises stay in records.
        actor = old.get("actor", "model")
        fields = journal_fields(old.get("fields", {}))
        at = old.get("event_at", old.get("at", 0))
        evidence = [{"ref": old.get("source") or f"{path}#judgment-{index}", "quote": old.get("quote")}]
        if op == "create":
            known.setdefault(identity, kind)
            label = fields.get("name")
            fields["name"] = (label.strip() if isinstance(label, str) else "") or identity
        elif op == "merge" and actor == "owner":
            identity = engine.resolve(identity, retired)
            target = engine.resolve(old.get("into"), retired)
            if identity == target or known.get(identity) != kind or known.get(target) != kind:
                continue
            retired[identity] = target
        elif op == "update" and known.get(identity) == kind and fields:
            # The old format let either actor update a display name. The engine
            # accepts repeated creates and can apply its field authority to them.
            if "name" in fields:
                fields["name"] = fields["name"].strip() if isinstance(fields["name"], str) else identity
                fields["name"] = fields["name"] or identity
                op = "create"
        else:
            continue  # Includes external corrections, which never created a local item.
        converted.append({"op": op, "id": identity, "kind": kind, "actor": actor, "at": at,
                          "fields": fields, "evidence": evidence,
                          **({"target": target} if op == "merge" else {}),
                          **({"direct": True} if old.get("direct") else {})})

    current = engine.replay(converted)["items"]
    names = {row["id"]: row["fields"]["name"] for row in converted if row["op"] == "create"}
    used = set(known)
    identities = {}
    for old, label in names.items():
        display = current.get(old, {}).get("name", label)
        new = engine.allocate(display, used - {old})
        identities[old] = new
        used.add(new)

    for row in converted:
        row["id"] = identities[row["id"]]
        if row["op"] == "merge":
            row["target"] = identities[row["target"]]
    for old, new in identities.items():
        if old != new:
            converted.append({"op": "redirect", "id": old, "target": new, "kind": known[old], "actor": "source",
                              "at": 0, "fields": {}, "evidence": [{"ref": str(path), "quote": None}]})
    return converted


class Journal:
    def __init__(self, root):
        self.path = root / "ontology.jsonl"
        self.revision = 0
        self.checkpoint_path = root / "ontology-positions.json"
        try:
            self.positions = json.loads(self.checkpoint_path.read_bytes())
        except FileNotFoundError:
            self.positions = {}
            old_path = root / "judgments.jsonl"
            if old_path.is_file():
                old = legacy_records(old_path)
                changes = convert_legacy(old, old_path)
                if changes:
                    engine.append(lambda _: changes, self.path, batch="tako-legacy-v1")
                for row in old:
                    if row.get("op") == "read":
                        self.positions.update(row.get("positions", {}))
                self.checkpoint(self.positions)
        self.reload()

    def reload(self):
        self.state = engine.load(self.path, with_field_records=True)

    def checkpoint(self, positions):
        # Position data is operational metadata, not an ontology judgment.
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with NamedTemporaryFile(dir=self.path.parent, delete_on_close=False) as out:
            out.write(engine.encode(positions).encode())
            out.flush()
            os.fsync(out.fileno())
            os.replace(out.name, self.checkpoint_path)
        self.positions = positions

    def append(self, build, positions=None):
        batch = None
        if positions is not None:
            # If a write succeeded but the cursors could not advance, retry
            # against the same batch without appending duplicate judgments.
            batch = "tako-traces:" + hashlib.sha256(engine.encode(positions).encode()).hexdigest()
        rows = engine.append(build, self.path, batch=batch)
        self.reload()
        self.revision += len(rows)
        if positions is not None:
            self.checkpoint(positions)
        return rows
