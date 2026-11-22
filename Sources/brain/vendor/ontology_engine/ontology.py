"""Replay an append-only ontology journal and look up its current state."""

import fcntl
import json
import math
import os
import re
import unicodedata
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path

KINDS = ("subject", "project", "action")
AUTHORITY = {"model": 0, "source": 1, "owner": 2}
UNASSIGNED = "未归属"
NAME_LISTS = {"aliases", "misrecognitions"}
LINKS = {
    "organization": "subject", "organization_id": "subject", "client": "subject",
    "people": "subject", "debtor": "subject", "creditor": "subject",
    "project": "project", "superseded_by": "action",
}
TERMINAL = {"completed", "cancelled", "superseded"}
RESERVED = {"id", "kind", "at", "source_updated_at", "evidence", "disagreements", "certainty"}
DEFAULT_STORE = Path(".local/ontology.jsonl")


def normalize(value):
    return unicodedata.normalize("NFKC", value).strip().casefold() if isinstance(value, str) else ""


def timestamp(value):
    if isinstance(value, str):
        try:
            stamp = datetime.fromisoformat(value)
            return (stamp if stamp.tzinfo else stamp.replace(tzinfo=UTC)).timestamp()
        except ValueError:
            return 0
    return value if type(value) in (int, float) else 0


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False)


def name(value):
    return isinstance(value, str) and bool(normalize(value)) and value == value.strip()


def allocate(label, used):
    """Allocate an identifier. A duplicate display name stays searchable."""
    taken = {normalize(value) for value in used}
    candidate, suffix = label, 2
    while normalize(candidate) in taken:
        candidate = f"{label} ({suffix})"
        suffix += 1
    return candidate


def validate(row):
    if not isinstance(row, dict):
        raise ValueError("record must be an object")
    op, kind, actor = (row.get(key) for key in ("op", "kind", "actor"))
    at, fields, evidence = (row.get(key) for key in ("at", "fields", "evidence"))
    if (op not in ("create", "update", "redirect", "merge", "review", "split") or kind not in KINDS
            or not isinstance(actor, str) or actor not in AUTHORITY or not name(row.get("id"))
            or type(at) not in (int, float) or not math.isfinite(at)
            or not isinstance(fields, dict) or RESERVED & fields.keys()):
        raise ValueError("invalid record header or fields")
    if not isinstance(evidence, list) or not evidence:
        raise ValueError("record needs evidence")
    for ref in evidence:
        if not isinstance(ref, dict) or not name(ref.get("ref")) or "quote" not in ref:
            raise ValueError("evidence needs a reference and a quote field")
        quote = ref["quote"]
        if quote is not None and (not isinstance(quote, str) or not quote.strip()):
            raise ValueError("quote must be verbatim text or legacy null")
    if op == "create" and not name(fields.get("name")):
        raise ValueError("creation needs a display name")
    if op == "update" and (not fields or "name" in fields):
        raise ValueError("update needs fields, use a redirect to rename")
    for key in NAME_LISTS | {"people", "home"}:
        if key in fields and (not isinstance(fields[key], list) or not all(map(name, fields[key]))):
            raise ValueError(f"invalid list field: {key}")
    for key in LINKS.keys() - {"people"}:
        if key in fields and fields[key] is not None and not name(fields[key]):
            raise ValueError(f"invalid name reference: {key}")
    if kind == "action" and (
            ((op == "create" or "project" in fields) and not name(fields.get("project")))
            or ((op == "create" or "people" in fields) and not fields.get("people"))):
        raise ValueError("action needs project and people, or 未归属")
    target = row.get("target")
    rename = op == "redirect" and set(fields) == {"name"} and name(fields["name"])
    if op in ("redirect", "merge") and (
            (fields and not rename) or (not name(target) and not (op == "merge" and actor == "owner" and target is None))
            or target == row["id"]):
        raise ValueError("invalid redirect or merge")
    if op == "split" and (actor != "owner" or fields or not name(target)
                          or target == row["id"] or not isinstance(row.get("refs"), list)
                          or not row["refs"] or not all(map(name, row["refs"]))):
        raise ValueError("split needs an owner, distinct target and evidence references")
    if op == "review" and (not isinstance(target, list) or not all(map(name, target))
                           or not name(row.get("reason"))):
        raise ValueError("invalid unresolved review")
    encode(row)


def resolve(identity, redirects):
    seen = set()
    while identity in redirects:
        if identity in seen:
            raise ValueError("redirect cycle")
        seen.add(identity)
        identity = redirects[identity]
    return identity


def unique(values):
    return list(dict.fromkeys(values))


def distinct_evidence(values):
    return list({encode(value): value for value in values}.values())


def certainty(name_actor, evidence):
    """Owner identity, one verbatim source identity, or two independent origins."""
    quoted = {re.sub(r"#L\d+(?:-L\d+)?$", "", ref["ref"]) for ref in evidence if ref["quote"]}
    if name_actor == "owner" or (name_actor == "source" and quoted) or len(quoted) >= 2:
        return "certain"
    return "uncertain"


def _placeholder(key, value):
    return key in LINKS and value in (UNASSIGNED, [UNASSIGNED])


def _field_rank(actor, key, value):
    # A migration placeholder provides no source-backed attribution.
    return -1 if actor == "source" and _placeholder(key, value) else AUTHORITY[actor]


def _pick(item, winners, row, key, value):
    actor = row["actor"]
    prior = winners.get(key)
    rank = _field_rank(actor, key, value)
    if prior is not None and rank < _field_rank(prior, key, item[key]):
        if actor != "owner" and _placeholder(key, value):
            return
        disputes = item.setdefault("disagreements", {})
        if item[key] != value:
            disputes[key] = {"value": value, "actor": actor, "evidence": row["evidence"]}
        elif disputes.get(key, {}).get("actor") == actor:
            disputes.pop(key)
        return
    if key in NAME_LISTS and actor == "source":
        value = unique([*item.get(key, []), *value])
    item[key], winners[key] = value, actor
    item.get("disagreements", {}).pop(key, None)
    return True


def _relations(rows, kinds):
    aliases, choices, disputes = {}, {}, {}
    for row in rows:
        identity, op, target = row["id"], row["op"], row.get("target")
        if op == "redirect":
            prior = aliases.get(identity)
            if prior and prior["target"] != target:
                # An explicit owner decision can repoint an old alias after a split.
                if identity in kinds or row["fields"] or prior["fields"]:
                    raise ValueError("conflicting redirects")
                if row["actor"] != "owner":
                    if prior["actor"] == "owner":
                        continue
                    raise ValueError("conflicting redirects")
            if not prior or AUTHORITY[row["actor"]] >= AUTHORITY[prior["actor"]]:
                aliases[identity] = row
    legacy = {key: row["target"] for key, row in aliases.items()}
    legacy_ids = {key: value for key, value in legacy.items() if key not in kinds}
    for row in rows:
        if row["op"] != "merge":
            continue
        identity = resolve(row["id"], legacy_ids)
        prior = choices.get(identity)
        if prior is None or AUTHORITY[row["actor"]] >= AUTHORITY[prior["actor"]]:
            choices[identity] = row
            disputes.pop(identity, None)
        elif row["target"] != prior["target"]:
            disputes[identity] = row
        elif disputes.get(identity, {}).get("actor") == row["actor"]:
            disputes.pop(identity)
    direct = {key: row["target"] for key, row in choices.items() if row["target"] is not None}
    direct.update(legacy)
    redirects = {key: resolve(key, direct) for key in direct}
    for row in rows:
        if row["op"] == "review":
            continue
        identity = resolve(row["id"], redirects)
        if kinds.get(identity) != row["kind"] or kinds.get(row["id"], row["kind"]) != row["kind"]:
            raise ValueError(f"missing identity or different kind: {row['id']}")
        if row["op"] == "merge" and row["target"] is not None:
            if kinds.get(resolve(row["target"], redirects)) != row["kind"]:
                raise ValueError(f"missing merge target or different kind: {row['target']}")
    return redirects, disputes


def replay(records, *, with_field_records=False):
    rows = list(records)
    for row in rows:
        validate(row)
    rows.sort(key=lambda row: row["at"])
    kinds = {}
    for row in rows:
        if row["op"] != "create":
            continue
        identity = row["id"]
        if kinds.setdefault(identity, row["kind"]) != row["kind"]:
            raise ValueError(f"identity has conflicting kinds: {identity}")
    for row in rows:
        if row["op"] != "redirect" or not row["fields"]:
            continue
        target = row["target"]
        if row["id"] not in kinds or target in kinds:
            raise ValueError("rename needs an existing origin and an unused target")
        kinds[target] = row["kind"]
    redirects, disputes = _relations(rows, kinds)
    items, winners, names, reviews, seen_reviews = {}, defaultdict(dict), defaultdict(list), {}, {}
    field_records = defaultdict(dict)
    confirmations, splits = set(), []
    for identity, kind in kinds.items():
        if identity not in redirects:
            items[identity] = {"id": identity, "kind": kind, "at": 0, "evidence": []}
            if kind == "subject":
                items[identity]["source_updated_at"] = 0
    for row in rows:
        identity = resolve(row["id"], redirects)
        if row["op"] == "review":
            review = {**row, "target": unique(resolve(target, redirects) for target in row["target"])}
            prior = reviews.get(row["id"])
            if prior and AUTHORITY[prior["actor"]] > AUTHORITY[row["actor"]]:
                continue
            reviews[row["id"]] = review
            if row["actor"] == "owner" and row["reason"] == "confirmed-identity":
                confirmations.update(review["target"])
            continue
        if row["op"] == "split":
            splits.append(row)
            continue
        item = items[identity]
        item["evidence"].extend(row["evidence"])
        if row["op"] in ("merge", "redirect"):
            if row["op"] == "redirect" and row.get("target") == identity and row["fields"]:
                picked = _pick(item, winners[identity], row, "name", row["fields"]["name"])
                if with_field_records and picked:
                    field_records[identity]["name"] = row
            continue
        for key, value in row["fields"].items():
            picked = _pick(item, winners[identity], row, key, value)
            if with_field_records and picked:
                field_records[identity][key] = row
        if row["op"] == "create" and (item["kind"] == "subject" or row["id"] != identity):
            names[identity].append(row["fields"]["name"])
        if item["kind"] == "subject":
            item["at"] = timestamp(item.get("mentioned_at"))
            item["source_updated_at"] = max(item["source_updated_at"], *(
                timestamp(ref.get("at")) if ref.get("source") == "project-file" else 0
                for ref in row["evidence"]))
        else:
            item["at"] = max(item["at"], row["at"])
    for row in splits:
        origin = resolve(row["id"], redirects)
        target = resolve(row["target"], redirects)
        # A later merge may intentionally bring the partition back together.
        if origin == target:
            continue
        if target not in items or items[target]["kind"] != row["kind"]:
            raise ValueError("missing split target or different kind")
        original = items[origin]["evidence"]
        moved = [ref for ref in original if ref["ref"] in row["refs"]]
        items[target]["evidence"].extend(moved)
        items[origin]["evidence"] = [ref for ref in original if ref["ref"] not in row["refs"]] + row["evidence"]
    for old, row in disputes.items():
        item = items[resolve(old, redirects)]
        item.setdefault("disagreements", {}).setdefault("merge", {})[old] = {
            "value": row["target"], "actor": row["actor"], "evidence": row["evidence"],
        }
    for identity, item in items.items():
        if names[identity] and winners[identity].get("aliases") != "owner":
            item["aliases"] = [label for label in unique([*item.get("aliases", []), *names[identity]])
                               if label != item["name"]]
        item["evidence"] = distinct_evidence(item["evidence"])
        actor = "owner" if identity in confirmations else winners[identity].get("name")
        item["certainty"] = certainty(actor, item["evidence"])
        if not item.get("disagreements"):
            item.pop("disagreements", None)
    for key, review in list(reviews.items()):
        if review["actor"] == "owner" and review["reason"] in ("confirmed-identity", "dismissed-review"):
            continue
        if review["reason"] != "ambiguous-identity":
            continue
        targets = tuple(sorted(review["target"]))
        if len(targets) < 2:
            del reviews[key]
        elif targets in seen_reviews:
            prior = reviews[seen_reviews[targets]]
            prior["evidence"] = distinct_evidence(prior["evidence"] + review["evidence"])
            prior["scope"] = "cross-file" if len({ref.get("path", ref["ref"]) for ref in prior["evidence"]}) > 1 else "same-file"
            del reviews[key]
        else:
            seen_reviews[targets] = key
    state = {"items": items, "redirects": redirects, "reviews": list(reviews.values())}
    if with_field_records:
        state["field_records"] = field_records
    return state


def _read(stream):
    for line_number, line in enumerate(stream, 1):
        if not line.strip():
            continue
        try:
            data = json.loads(line)
            if isinstance(data, dict) and set(data) == {"records"}:
                if not isinstance(data["records"], list) or not data["records"]:
                    raise ValueError("journal batch needs records")
                yield from data["records"]
            else:
                yield data
        except ValueError as exc:
            raise ValueError(f"invalid journal line {line_number}: {exc}") from exc


def load(path=DEFAULT_STORE, *, with_field_records=False):
    try:
        with Path(path).open("rb") as stream:
            fcntl.flock(stream, fcntl.LOCK_SH)
            return replay(_read(stream), with_field_records=with_field_records)
    except FileNotFoundError:
        return replay([], with_field_records=with_field_records)


def append(make_records, path=DEFAULT_STORE, *, with_field_records=False, batch=None):
    """Build and validate an append against the locked current journal."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_NOFOLLOW | os.O_APPEND | os.O_CREAT | os.O_RDWR, 0o600), "a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        previous = list(_read(stream))
        if batch is not None and any(row.get("scan_batch") == batch for row in previous):
            return []
        new = list(make_records(replay(previous, with_field_records=with_field_records)))
        if new:
            if batch is not None:
                new[0] = {**new[0], "scan_batch": batch}
            replay([*previous, *new])
            payload = encode(new[0] if len(new) == 1 else {"records": new})
            stream.seek(0, os.SEEK_END)
            prefix = ""
            if stream.tell():
                stream.seek(-1, os.SEEK_END)
                prefix = "" if stream.read(1) == b"\n" else "\n"
            stream.write((prefix + payload + "\n").encode())
            stream.flush()
            os.fsync(stream.fileno())
    return new


def _labels(state):
    labels = defaultdict(set)
    for identity, item in state["items"].items():
        for value in (identity, item["name"], *item.get("aliases", []), *item.get("misrecognitions", [])):
            labels[normalize(value)].add(identity)
    for old, target in state["redirects"].items():
        labels[normalize(old)].add(target)
    return labels


def find(state, value):
    if value in state["redirects"]:
        return [state["redirects"][value]]
    return sorted(_labels(state).get(normalize(value), ()))


def link_targets(state, item, labels=None):
    if labels is None:
        labels = _labels(state)
    for field, kind in LINKS.items():
        if field == "organization_id" and "organization" in item:
            continue
        subject_type = "organization" if field in {"organization", "organization_id", "client"} else None
        value = item.get(field)
        for term in value if isinstance(value, list) else [value]:
            if term in (None, UNASSIGNED):
                continue
            canonical = state["redirects"].get(term, term)
            target = state["items"].get(canonical, {})
            if target.get("kind") == kind and (subject_type is None or target.get("type") in (None, subject_type)):
                yield canonical
                continue
            matches = [key for key in labels.get(normalize(term), ())
                       if state["items"][key]["kind"] == kind
                       and (subject_type is None or state["items"][key].get("type") in (None, subject_type))]
            if len(matches) == 1:
                yield matches[0]


def related(state, roots):
    roots = set(roots)
    items = state["items"]
    labels = _labels(state)
    links = {key: set(link_targets(state, item, labels)) for key, item in items.items()}
    incoming = {key for key, targets in links.items() if targets & roots}
    extra = {key for key in incoming if items[key]["kind"] != "action"}
    actions = {key for key, targets in links.items() if items[key]["kind"] == "action" and targets & extra}
    outgoing = set().union(*(links[key] for key in roots))
    return sorted((incoming | actions | outgoing) - roots)


def query(state, *, identity=None, kind=None, question=None):
    items = state["items"]
    if identity is not None:
        matches = find(state, identity)
    elif question is not None:
        text = normalize(question)
        labels = _labels(state)
        hits = [label for label in labels if label and label in text and (
            not label.isascii() or re.search(r"(?<!\w)" + re.escape(label) + r"(?!\w)", text, re.ASCII))]
        longest = [label for label in hits if not any(label != other and label in other for other in hits)]
        matches = sorted(set().union(*(labels[label] for label in longest)))
        if not matches and text:
            words = set(re.findall(r"[a-z0-9]+", text))
            for part in re.findall(r"[\u3400-\u9fff]+", text):
                words.update(part[index:index + 2] for index in range(len(part) - 1))
            words -= {"请问", "这个", "那个", "了吗", "怎么", "如何", "现在", "还有", "什么", "几件", "哪些"}
            scores = {}
            for key, item in items.items():
                title = normalize(item["name"])
                context = [normalize(item.get(field)) for field in ("next", "summary", "project_label")]
                score = sum(2 if word in title else int(any(word in value for value in context)) for word in words)
                if score:
                    scores[key] = score
            matches = sorted(scores, key=lambda key: (-scores[key], key))
    else:
        matches = list(items)
    relatives = related(state, matches) if (identity is not None or question is not None) and matches else []
    return {label: [items[key] for key in keys if kind is None or items[key]["kind"] == kind]
            for label, keys in (("matches", matches), ("related", relatives))}
