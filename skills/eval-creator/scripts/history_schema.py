"""Validate small experiment summaries without reading their evidence."""
import re
import math
from datetime import date, datetime
from urllib.parse import urlsplit

from report_schema import array, is_revision_link, number, obj, require, text, texts, unique

COUNT_FIELDS = ("found", "missed", "false_positives", "unresolved")
FIX_SAFETY_FIELDS = ("unsafe_fix_suggestions", "unresolved_fix_suggestions")
NOVEL_FIELDS = ("defect", "documentation", "test_gap")
USAGE_FIELDS = ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens")


def sibling_filename(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,200}", value))


def https_url(value):
    return isinstance(value, str) and value.startswith("https://") and is_revision_link(value)


def normalize_percent_case(value):
    return re.sub(r"%[0-9A-Fa-f]{2}", lambda match: match.group().upper(), value)


def evidence_refs(data):
    for experiment in data["experiments"]:
        yield from experiment.get("evidence", [])
        yield experiment["dataset_evidence"]
        for group in experiment.get("qualification", []):
            for attempt in group["attempts"]:
                yield from attempt["evidence"]
                yield from attempt["usage"].get("evidence", [])
        for refusal in experiment.get("prelaunch_refusals", []):
            yield from refusal["evidence"]
    for archive in data["archives"]:
        yield from archive.get("evidence", [])
        proof = archive.get("backup_verification") or {}
        for key in ("manifest", "restore_report"):
            if key in proof:
                yield proof[key]
    for run in data["runs"]:
        yield from run["evidence"]
        yield from run["usage"].get("evidence", [])
        yield from (run.get("setup_attempts") or {}).get("evidence", [])
        for grade in run["grading"]:
            yield from grade.get("evidence", [])
            yield from grade.get("assessed_outputs", [])
            yield from (grade.get("replay_usage") or {}).get("evidence", [])
            yield grade["rubric"]["evidence"]
            if "grader" in grade:
                yield grade["grader"]["procedure"]
        for key in ("grading_usage", "replay_usage"):
            yield from (run.get(key) or {}).get("evidence", [])
        campaign = run.get("campaign") or {}
        yield from campaign.get("evidence", [])
        yield from (campaign.get("grader_usage") or {}).get("evidence", [])


def consistent_evidence_digests(data):
    seen = {}
    for ref in evidence_refs(data):
        if ref.get("sha256") is None:
            continue
        digest = ref["sha256"].lower()
        locations = []
        if "archive_id" in ref:
            locations.append(("archive", ref["archive_id"], ref["member"]))
        if ref.get("path") is not None:
            path = ref["path"]
            if path.startswith("https://"):
                parsed = urlsplit(path)
                has_query = "?" in path.partition("#")[0]
                locations.append(("https", parsed.hostname, parsed.port or 443,
                                  normalize_percent_case(parsed.path), has_query, normalize_percent_case(parsed.query)))
            else:
                locations.append(("path", path))
        for location in locations:
            require(seen.setdefault(location, digest) == digest, "conflicting checksums for one evidence location")


def evidence(items, archives, path):
    for ref in array(items, path):
        obj(ref, path)
        text(ref.get("label"), path + ".label")
        if ref.get("path") is not None:
            require(sibling_filename(ref["path"]) or https_url(ref["path"]),
                    path + ".path: use HTTPS or a plain filename in the report directory")
        if "archive_id" in ref or "member" in ref:
            require(ref.get("archive_id") in archives, path + ": unknown archive reference")
            text(ref.get("member"), path + ".member")
        if ref.get("sha256") is not None:
            require(isinstance(ref["sha256"], str) and re.fullmatch(r"[0-9a-fA-F]{64}", ref["sha256"]),
                    path + ": invalid SHA-256")
        if ref.get("note") is not None:
            text(ref["note"], path + ".note")


def frozen_evidence(ref, archives, path, remote=False):
    obj(ref, path)
    evidence([ref], archives, path)
    require(ref.get("sha256") is not None, path + ": frozen evidence needs SHA-256")
    require(https_url(ref.get("path")) if remote else bool(ref.get("path") or ref.get("archive_id")),
            path + ": frozen evidence needs " + ("an HTTPS location" if remote else "a location"))


def backup(archive, archives):
    state = archive.get("backup_status")
    require(state in ("local-only", "backup-unverified", "backup-verified"), "archive: invalid backup status")
    if state == "backup-unverified":
        require(bool(archive.get("location")) or any(https_url(ref.get("path")) for ref in archive.get("evidence", [])),
                "backup: an unverified backup needs a destination")
    proof = archive.get("backup_verification")
    if state != "backup-verified" and proof is None:
        return
    require(state == "backup-verified", "backup: verification proof requires backup-verified status")
    obj(proof, "backup_verification")
    digest = proof.get("sha256")
    require(isinstance(digest, str) and re.fullmatch(r"[0-9a-fA-F]{64}", digest), "backup: invalid archive SHA-256")
    number(proof.get("member_count"), "backup.member_count", integer=True, nullable=False)
    require(proof["member_count"] > 0, "backup: restored archive needs members")
    recorded_date(proof.get("verified_on"), "backup.verified_on")
    require(proof.get("downloaded_archive_matches") is True and proof.get("restored_members_match") is True,
            "backup: downloaded archive and restored members must match")
    for key in ("manifest", "restore_report"):
        frozen_evidence(proof.get(key), archives, "backup." + key, remote=True)
    require(any(https_url(ref.get("path")) and isinstance(ref.get("sha256"), str)
                and ref["sha256"].lower() == digest.lower()
                for ref in archive.get("evidence", [])), "backup: no download evidence matches archive SHA-256")


def attempts(run, experiment):
    expected = len(experiment["case_ids"]) * experiment["repetitions"]
    require(run["planned"] == expected, "run: planned trials must match experiment cases and repetitions")
    seen, completed = set(), 0
    for attempt in array(run.get("attempts"), "run.attempts"):
        obj(attempt, "run.attempts")
        case, repetition = attempt.get("case_id"), attempt.get("repetition")
        require(case in experiment["case_ids"], "run.attempts: unknown case")
        number(repetition, "run.attempts.repetition", integer=True, nullable=False)
        require(1 <= repetition <= experiment["repetitions"], "run.attempts: repetition outside plan")
        key = case, repetition
        require(key not in seen, "run.attempts: duplicate case and repetition")
        seen.add(key)
        require(attempt.get("status") in ("completed", "pending", "failed", "cancelled", "skipped"),
                "run.attempts: invalid status")
        completed += attempt["status"] == "completed"
    require(len(seen) == expected, "run.attempts: must cover every planned case and repetition")
    require(completed == run["completed"], "run.attempts: completed count disagrees with attempts")


def resources(value, archives, path):
    obj(value, path)
    number(value.get("seconds"), path + ".seconds")
    for key in USAGE_FIELDS:
        number(value.get(key), path + "." + key, integer=True)
    for subset, total in (("cached_input_tokens", "input_tokens"), ("reasoning_output_tokens", "output_tokens")):
        require(value.get(subset) is None or value.get(total) is None or value[subset] <= value[total],
                path + ": token subset exceeds total")
    for key in ("id", "scope", "note"):
        if value.get(key) is not None:
            text(value[key], path + "." + key)
    evidence(value.get("evidence", []), archives, path + ".evidence")


def qualification(experiment, archives):
    calls, receipts, labels = 0, set(), set()
    for group in array(experiment.get("qualification", []), "experiment.qualification"):
        obj(group, "qualification")
        for key in ("label", "status"):
            text(group.get(key), "qualification." + key)
        if group.get("note") is not None:
            text(group["note"], "qualification.note")
        require(group["label"] not in labels, "qualification: duplicate configuration label")
        labels.add(group["label"])
        attempts_seen = set()
        attempts_list = array(group.get("attempts"), "qualification.attempts")
        require(bool(attempts_list), "qualification.attempts must not be empty")
        for attempt in attempts_list:
            obj(attempt, "qualification.attempt")
            number(attempt.get("attempt"), "qualification.attempt", integer=True, nullable=False)
            require(attempt["attempt"] > 0 and attempt["attempt"] not in attempts_seen,
                    "qualification: attempt numbers must be positive and unique per configuration")
            attempts_seen.add(attempt["attempt"])
            text(attempt.get("status"), "qualification.attempt.status")
            resources(attempt.get("usage"), archives, "qualification.usage")
            for key in ("started_utc", "ended_utc"):
                if attempt.get(key) is not None:
                    recorded_date(attempt[key], "qualification." + key, timestamp_only=True)
            if attempt.get("started_utc") is not None and attempt.get("ended_utc") is not None:
                require(datetime.fromisoformat(attempt["ended_utc"]) >= datetime.fromisoformat(attempt["started_utc"]),
                        "qualification: end precedes start")
            refs = array(attempt.get("evidence"), "qualification.evidence")
            require(bool(refs), "qualification: frozen attempt receipt required")
            for ref in refs:
                frozen_evidence(ref, archives, "qualification.evidence")
            receipt = refs[0]["sha256"].lower()
            require(receipt not in receipts, "qualification: duplicate attempt receipt")
            receipts.add(receipt)
            calls += 1
    if "qualification" in experiment or "qualification_model_calls" in experiment:
        number(experiment.get("qualification_model_calls"), "qualification_model_calls", integer=True, nullable=False)
        require(experiment["qualification_model_calls"] == calls, "qualification_model_calls disagrees with attempts")
    for refusal in array(experiment.get("prelaunch_refusals", []), "prelaunch_refusals"):
        obj(refusal, "prelaunch_refusal")
        for key in ("status", "reason"):
            text(refusal.get(key), "prelaunch_refusal." + key)
        if refusal.get("evidence_note") is not None:
            text(refusal["evidence_note"], "prelaunch_refusal.evidence_note")
        require(refusal.get("model_started") is False, "prelaunch_refusal: model_started must be false")
        refs = array(refusal.get("evidence"), "prelaunch_refusal.evidence")
        require(bool(refs), "prelaunch_refusal: frozen evidence required")
        for ref in refs:
            frozen_evidence(ref, archives, "prelaunch_refusal.evidence")


def shared_record(record, seen, path):
    text(record.get("id"), path + ".id")
    ident = record["id"]
    require(ident not in seen or record == seen[ident], path + ": conflicting records for shared ID")
    seen[ident] = record


def recorded_date(value, path, timestamp_only=False):
    text(value, path)
    try:
        if not timestamp_only and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
            date.fromisoformat(value)
        else:
            require(bool(re.match(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T", value)), "invalid ISO timestamp")
            require(datetime.fromisoformat(value).tzinfo is not None, "timestamp needs a timezone")
    except ValueError as error:
        expected = "an ISO timestamp with a timezone" if timestamp_only else "an ISO date or timestamp with a timezone"
        raise ValueError(path + ": use " + expected) from error


def assessed_attempts(grade, run):
    if grade["status"] != "partial" and "assessed_attempts" not in grade:
        return
    rows = array(grade.get("assessed_attempts"), "grading.assessed_attempts")
    require(len(rows) == grade["graded_trials"], "grading.assessed_attempts must match graded_trials")
    completed = {(row["case_id"], row["repetition"]) for row in run["attempts"] if row["status"] == "completed"}
    seen = set()
    for row in rows:
        obj(row, "grading.assessed_attempts")
        text(row.get("case_id"), "grading.assessed_attempts.case_id")
        number(row.get("repetition"), "grading.assessed_attempts.repetition", integer=True, nullable=False)
        key = row["case_id"], row["repetition"]
        require(key in completed, "grading.assessed_attempts must reference completed run attempts")
        require(key not in seen, "grading.assessed_attempts must not repeat an attempt")
        seen.add(key)


def grading(run, archives, shared_replays):
    rows = run.get("grading")
    unique(rows, "run.grading")
    seen = set()
    for grade in rows:
        state = grade.get("status")
        require(state in ("complete", "partial", "unavailable"), "grading: invalid status")
        rubric = obj(grade.get("rubric"), "grading.rubric")
        text(rubric.get("id"), "grading.rubric.id")
        frozen_evidence(rubric.get("evidence"), archives, "grading.rubric.evidence")
        text(grade.get("reviewer"), "grading.reviewer")
        if state != "unavailable" or "grader" in grade:
            grader = obj(grade.get("grader"), "grading.grader")
            for key in ("id", "label", "note"):
                text(grader.get(key), "grading.grader." + key)
            frozen_evidence(grader.get("procedure"), archives, "grading.grader.procedure")
        if state != "unavailable" or grade.get("graded_at") is not None:
            recorded_date(grade.get("graded_at"), "grading.graded_at")
        if state != "unavailable":
            started = datetime.fromisoformat(run["started_at"])
            assessed = grade["graded_at"]
            not_before = (date.fromisoformat(assessed) >= started.date() if len(assessed) == 10
                          else datetime.fromisoformat(assessed) >= started)
            require(not_before, "grading.graded_at must not be before its run starts")
        outputs = array(grade.get("assessed_outputs", []), "grading.assessed_outputs")
        require(state == "unavailable" or bool(outputs), "grading.assessed_outputs: measured grades need frozen outputs")
        for ref in outputs:
            frozen_evidence(ref, archives, "grading.assessed_outputs")
        count = grade.get("graded_trials")
        number(count, "grading.graded_trials", integer=True, nullable=False)
        require(count <= run["completed"], "grading: graded trials exceed completed trials")
        assessed_attempts(grade, run)
        novel = obj(grade.get("novel"), "grading.novel")
        values = [grade.get(key) for key in COUNT_FIELDS] + [novel.get(key) for key in NOVEL_FIELDS]
        for value in values:
            number(value, "grading count", integer=True, nullable=state != "complete")
        if "standards_advisories" in grade:
            number(grade["standards_advisories"], "grading.standards_advisories",
                   integer=True, nullable=state != "complete")
            values.append(grade["standards_advisories"])
        supplied_safety = [key for key in FIX_SAFETY_FIELDS if key in grade]
        require(len(supplied_safety) in (0, len(FIX_SAFETY_FIELDS)),
                "grading: unsafe and unresolved fix suggestion counts must be supplied together")
        for key in supplied_safety:
            number(grade[key], "grading." + key, integer=True, nullable=state != "complete")
            values.append(grade[key])
        reasons = grade.get("unknown_reasons")
        if reasons is not None:
            obj(reasons, "grading.unknown_reasons")
            for key, reason in reasons.items():
                require(key in COUNT_FIELDS + ("novel",) + FIX_SAFETY_FIELDS,
                        f"grading.unknown_reasons.{key}: not a quality count")
                text(reason, f"grading.unknown_reasons.{key}")
                current = list(novel.values()) if key == "novel" else [grade.get(key)]
                require(any(value is None for value in current), f"grading.unknown_reasons.{key}: the value is known")
        if grade.get("unknown_reason") is not None:
            text(grade["unknown_reason"], "grading.unknown_reason")
        fixed = grade.get("fixed_bugs_reported_again")
        number(fixed, "grading.fixed_bugs_reported_again", integer=True)
        known = [grade.get("found"), grade.get("missed")]
        require(sum(value or 0 for value in known) <= run["known_bug_count"],
                "grading: found and missed exceed known bug count")
        if state == "complete":
            require(count == run["planned"], "grading: complete grade needs all planned trials")
            require(sum(known) == run["known_bug_count"], "grading: complete known bug counts disagree")
        if state == "unavailable":
            require(count == 0 and all(value is None for value in values + [fixed]),
                    "grading: unavailable grades must have unknown counts and zero graded trials")
        if count == 0:
            require(all(value is None for value in values + [fixed]),
                    "grading: zero graded trials must have unknown counts")
        if state == "partial":
            require(all(value is None for value in values + [fixed]),
                    "grading: partial aggregate quality counts must remain unknown")
        if grade.get("supersedes") is not None:
            require(grade["supersedes"] in seen, "grading: supersedes must reference an earlier grade")
        seen.add(grade["id"])
        replay = grade.get("replay_usage")
        if replay is not None:
            resources(replay, archives, "grading.replay_usage")
            shared_record(replay, shared_replays, "shared replay")
            require(bool(replay.get("evidence")), "grading.replay_usage: frozen replay evidence required")
            for ref in replay["evidence"]:
                frozen_evidence(ref, archives, "grading.replay_usage.evidence")
        evidence(grade.get("evidence", []), archives, "grading.evidence")
        if grade.get("note") is not None:
            text(grade["note"], "grading.note")


def validate(data):
    obj(data, "history")
    require(type(data.get("schema_version")) is int and data["schema_version"] == 1,
            "schema_version must be 1")
    for key in ("title", "purpose"):
        text(data.get(key), key)
    texts(data.get("limitations"), "limitations")
    collections = {key: unique(data.get(key), key)
                   for key in ("candidates", "experiments", "runs", "decisions", "archives")}
    if data.get("installed_candidate_id") is not None:
        require(data["installed_candidate_id"] in collections["candidates"], "unknown installed candidate")
        recorded_date(data.get("installed_checked_at"), "installed_checked_at")
    for archive in data["archives"]:
        for key in ("label", "owner", "access_policy", "retention_policy"):
            text(archive.get(key), "archive." + key)
        for key in ("location", "backup_status", "note"):
            if archive.get(key) is not None:
                text(archive[key], "archive." + key)
        evidence(archive.get("evidence", []), collections["archives"], "archive.evidence")
        backup(archive, collections["archives"])
    for candidate in data["candidates"]:
        for key in ("label", "revision", "runtime"):
            text(candidate.get(key), "candidate." + key)
        require(https_url(candidate.get("revision_url")), "candidate.revision_url must use HTTPS")
        require(re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", candidate["revision"]),
                "candidate.revision must be a full immutable Git revision")
        commit_path = urlsplit(candidate["revision_url"]).path.rstrip("/").split("/")
        require(len(commit_path) >= 3 and commit_path[-2] in ("commit", "commits")
                and commit_path[-1].lower() == candidate["revision"].lower(),
                "candidate.revision_url must link to the same commit")
        texts(candidate.get("changes"), "candidate.changes")
        configuration = candidate.get("configuration")
        if configuration is not None:
            obj(configuration, "candidate.configuration")
            if configuration.get("installed_checked_on") is not None:
                recorded_date(configuration["installed_checked_on"], "candidate.configuration.installed_checked_on")
            if configuration.get("service_tier_override") is not None:
                text(configuration["service_tier_override"], "candidate.configuration.service_tier_override")
            if "actual_backend_service_tier_attested" in configuration:
                require(type(configuration["actual_backend_service_tier_attested"]) is bool,
                        "candidate.configuration.actual_backend_service_tier_attested must be boolean")
    for experiment in data["experiments"]:
        qualification(experiment, collections["archives"])
        for key in ("question", "dataset", "rubric", "scope"):
            text(experiment.get(key), "experiment." + key)
        cases = array(experiment.get("case_ids"), "experiment.case_ids")
        texts(cases, "experiment.case_ids")
        require(bool(cases) and len(set(cases)) == len(cases), "experiment: need unique case IDs")
        number(experiment.get("repetitions"), "experiment.repetitions", integer=True, nullable=False)
        require(experiment["repetitions"] > 0, "experiment.repetitions must be positive")
        policy = obj(experiment.get("time_policy"), "experiment.time_policy")
        text(policy.get("label"), "time_policy.label")
        for key in ("trial_seconds", "campaign_seconds"):
            require(key in policy, "time_policy: numeric limits must be explicit")
            number(policy[key], "time_policy." + key)
            mode = policy.get(key.replace("seconds", "limit_status"))
            require(mode in ("bounded", "unlimited", "unknown"), "time_policy: invalid limit status")
            require(policy[key] is not None and policy[key] > 0 if mode == "bounded" else policy[key] is None,
                    "time_policy: bounded limits need positive seconds; unlimited and unknown need null")
        if experiment.get("note") is not None:
            text(experiment["note"], "experiment.note")
        evidence(experiment.get("evidence", []), collections["archives"], "experiment.evidence")
        frozen_evidence(experiment.get("dataset_evidence"), collections["archives"], "experiment.dataset_evidence")
    experiments = {row["id"]: row for row in data["experiments"]}
    shared_campaigns, shared_replays = {}, {}
    known_maxima = {}
    for run in data["runs"]:
        text(run.get("label"), "run.label")
        recorded_date(run.get("started_at"), "run.started_at", timestamp_only=True)
        for key, collection in (("experiment_id", "experiments"), ("candidate_id", "candidates")):
            require(run.get(key) in collections[collection], "run: unknown " + key)
        require(run.get("status") in ("completed", "incomplete", "failed", "cancelled"), "run: invalid status")
        if run["status"] != "completed":
            text(run.get("note"), "run.note interruption reason")
        for key in ("planned", "completed", "known_bug_count"):
            number(run.get(key), "run." + key, integer=True, nullable=False)
        experiment_id = run["experiment_id"]
        require(experiment_id not in known_maxima or known_maxima[experiment_id] == run["known_bug_count"],
                "run: known bug maximum must be consistent within an experiment")
        known_maxima[experiment_id] = run["known_bug_count"]
        require(run["planned"] > 0 and run["completed"] <= run["planned"], "run: invalid trial counts")
        require((run["status"] == "completed") == (run["completed"] == run["planned"]),
                "run: completed status must match completion of all planned trials")
        attempts(run, experiments[run["experiment_id"]])
        number(run.get("wall_seconds"), "run.wall_seconds")
        if run.get("wall_seconds_scope") is not None:
            text(run["wall_seconds_scope"], "run.wall_seconds_scope")
        resources(run.get("usage"), collections["archives"], "run.usage")
        for key in ("grading_usage", "replay_usage"):
            if run.get(key) is not None:
                resources(run[key], collections["archives"], "run." + key)
        if run.get("replay_usage") is not None:
            shared_record(run["replay_usage"], shared_replays, "shared replay")
        campaign = run.get("campaign")
        if campaign is not None:
            obj(campaign, "run.campaign")
            for key in ("scope", "note", "status"):
                if campaign.get(key) is not None:
                    text(campaign[key], "run.campaign." + key)
            for key in ("seconds", "review_seconds", "other_seconds"):
                number(campaign.get(key), "run.campaign." + key)
            total, reviewer, other = (campaign.get(key) for key in ("seconds", "review_seconds", "other_seconds"))
            if total is not None:
                for component in (reviewer, other):
                    require(component is None or component <= total
                            or math.isclose(component, total, rel_tol=1e-9, abs_tol=0.001),
                            "run.campaign: a wall-time partition component cannot exceed total time")
            if all(value is not None for value in (total, reviewer, other)):
                require(math.isclose(reviewer + other, total, rel_tol=1e-9, abs_tol=0.001),
                        "run.campaign: reviewer and other wall time must partition total time")
            if campaign.get("grader_usage") is not None:
                resources(campaign["grader_usage"], collections["archives"], "run.campaign.grader_usage")
            evidence(campaign.get("evidence", []), collections["archives"], "run.campaign.evidence")
            shared_record(campaign, shared_campaigns, "shared campaign")
        grading(run, collections["archives"], shared_replays)
        evidence(run.get("evidence"), collections["archives"], "run.evidence")
        setup = run.get("setup_attempts")
        if setup is not None:
            obj(setup, "run.setup_attempts")
            evidence(setup.get("evidence", []), collections["archives"], "run.setup_attempts.evidence")
        if run.get("note") is not None:
            text(run["note"], "run.note")
        estimate = run.get("resource_estimate")
        if estimate is not None:
            obj(estimate, "resource_estimate")
            number(estimate.get("value"), "resource_estimate.value", nullable=False)
            for key in ("unit", "method", "note"):
                text(estimate.get(key), "resource_estimate." + key)
            recorded_date(estimate.get("rate_date"), "resource_estimate.rate_date")
            require(https_url(estimate.get("source_url")), "resource_estimate.source_url must use HTTPS")
    run_grades = {row["id"]: {grade["id"] for grade in row["grading"]} for row in data["runs"]}
    for decision in data["decisions"]:
        require(decision.get("status") in ("investigate", "reject", "adopt", "defer"), "decision: invalid status")
        text(decision.get("text"), "decision.text")
        refs = array(decision.get("run_ids"), "decision.run_ids")
        texts(refs, "decision.run_ids")
        require(bool(refs) and all(ref in collections["runs"] for ref in refs), "decision: unknown run reference")
        seen = set()
        for ref in array(decision.get("grade_refs"), "decision.grade_refs"):
            obj(ref, "decision.grade_refs")
            run_id, grade_id = ref.get("run_id"), ref.get("grade_id")
            text(run_id, "decision.grade_refs.run_id")
            text(grade_id, "decision.grade_refs.grade_id")
            require(run_id in run_grades and grade_id in run_grades[run_id], "decision: unknown grade reference")
            require((run_id, grade_id) not in seen, "decision: duplicate grade reference")
            seen.add((run_id, grade_id))
        require(len(refs) == len(set(refs)) and {run for run, _ in seen} == set(refs),
                "decision: run_ids must match frozen grade references")
    consistent_evidence_digests(data)
