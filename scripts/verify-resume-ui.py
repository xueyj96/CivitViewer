#!/usr/bin/env python3
import hashlib
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required = {"dismiss", "restore-success", "restore-failure", "readback-consumed", "readback-new"}
failures = []

def require(ok, message):
    if not ok:
        failures.append(message)

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

cases = {}
for directory in sorted(p for p in root.iterdir() if p.is_dir()):
    receipt_path = directory / "receipt.json"
    if not receipt_path.exists():
        continue
    receipt = json.loads(receipt_path.read_text())
    case = receipt["scenario"]
    require(case not in cases, f"duplicate evidence for {case}")
    require(directory.name == f"{case}-{receipt['runID']}", f"{case}: directory/runID mismatch")
    require(receipt["evidenceFromSingleRun"] is True, f"{case}: receipt does not assert single-run evidence")
    require(receipt["signingAllowed"] is False, f"{case}: signing was enabled")
    manifest = directory / "source-manifest.sha256"
    require(manifest.exists(), f"{case}: source manifest missing")
    require(sha256(manifest) == receipt["sourceManifestSHA256"], f"{case}: source manifest hash mismatch")
    artifact_manifest = directory / "artifacts.sha256"
    require(artifact_manifest.exists(), f"{case}: artifact manifest missing")
    require(sha256(artifact_manifest) == receipt["artifactManifestSHA256"], f"{case}: artifact manifest hash mismatch")
    for row in artifact_manifest.read_text().splitlines():
        expected, rel = row.split("  ", 1)
        target = directory / rel.removeprefix("./")
        require(target.exists(), f"{case}: manifest target missing: {target.name}")
        require(sha256(target) == expected, f"{case}: artifact hash mismatch: {target.name}")
    cases[case] = (directory, receipt)

require(set(cases) == required, f"scenario coverage mismatch: got {sorted(cases)}")
run_ids = [receipt["runID"] for _, receipt in cases.values()]
require(len(run_ids) == len(set(run_ids)), "scenario runIDs are not unique")

def read(case, phase):
    directory, receipt = cases[case]
    path = directory / f"{phase}.json"
    require(path.exists(), f"{case}: missing {phase}.json")
    value = json.loads(path.read_text())
    require(value.get("runID") == receipt["runID"], f"{case}/{phase}: snapshot runID mismatch")
    return value

def same_rect(a, b, label):
    require(a is not None and b is not None, f"{label}: missing geometry")
    for component in ("x", "y", "width", "height"):
        require(math.isclose(a[component], b[component], abs_tol=0.1), f"{label}: {component} changed: {a} vs {b}")

for case in ("dismiss", "restore-success", "restore-failure"):
    initial = read(case, "initial")
    exposed = read(case, "after-exposure")
    tab1 = read(case, "tab-return-1s")
    tab3 = read(case, "tab-return-3s")
    require(initial["showsPrompt"], f"{case}: initial resume offer absent")
    require(initial["baselineOfferFocusedID"] == initial["visibleCandidateFocusedID"], f"{case}: initial offer mismatch")
    require(exposed["historyRecordIDs"] and 28029102 in exposed["historyRecordIDs"], f"{case}: actual history record missing")
    require(exposed["archiveCheckpointFocusedID"] == 28029102, f"{case}: exposure did not move archive checkpoint")
    require(exposed["archiveCheckpointUpdatedAt"] > initial["archiveCheckpointUpdatedAt"], f"{case}: checkpoint timestamp did not advance")
    require(exposed["baselineOfferFocusedID"] == initial["baselineOfferFocusedID"], f"{case}: process baseline changed with archive checkpoint")
    require(exposed["baselineOfferUpdatedAt"] == initial["baselineOfferUpdatedAt"], f"{case}: baseline timestamp mutated")
    require(exposed["baselineOfferSignature"] == initial["baselineOfferSignature"], f"{case}: baseline signature changed")
    require(exposed["archiveCheckpointSignature"] != initial["archiveCheckpointSignature"], f"{case}: archive checkpoint signature did not change")
    for phase, snapshot in (("after-exposure", exposed), ("tab-return-1s", tab1), ("tab-return-3s", tab3)):
        require(not snapshot["showsPrompt"], f"{case}/{phase}: consumed offer returned")
        same_rect(initial["viewportFrame"], snapshot["viewportFrame"], f"{case}/{phase} viewport")
        same_rect(snapshot["viewportFrame"], snapshot["focusedPageFrame"], f"{case}/{phase} page vs viewport")
        same_rect(exposed["actionsFrame"], snapshot["actionsFrame"], f"{case}/{phase} actions")
    background = read(case, "scene-background")
    foreground = read(case, "scene-active")
    require(background["scenePhase"] == "background", f"{case}: background scene readback mismatch")
    require(foreground["scenePhase"] == "active", f"{case}: active scene readback mismatch")

require(not read("dismiss", "after-dismiss")["showsPrompt"], "dismiss: prompt remained after production dismissPrompt")
restored = read("restore-success", "after-restore")
require(restored["restoreState"].startswith("resumed-"), "restore-success: production restore did not resume")
require(restored["focusedID"] == 28029101, "restore-success: production restore focus mismatch")
require(not restored["showsPrompt"], "restore-success: consumed offer remained visible")
failed = read("restore-failure", "after-restore")
require(failed["restoreState"] == "browsing", "restore-failure: state did not return to browsing")
require(failed["message"] is not None, "restore-failure: expected failure message missing")
require(failed["feedIDs"] == read("restore-failure", "initial")["feedIDs"], "restore-failure: prior feed was not preserved")
require(failed["focusedID"] == read("restore-failure", "initial")["focusedID"], "restore-failure: prior focus was not preserved")

consumed_dir, consumed_receipt = cases["readback-consumed"]
new_dir, new_receipt = cases["readback-new"]
for name, receipt in (("readback-consumed", consumed_receipt), ("readback-new", new_receipt)):
    require("independent seeded persisted checkpoint fixture on a fresh app process" in receipt["scenarioScope"], f"{name}: not labeled as independent seed")
    require("not a restart of a preceding dismiss/exposure run" in receipt["scenarioScope"], f"{name}: restart scope is ambiguous")
consumed = read("readback-consumed", "process-readback")
new_offer = read("readback-new", "process-readback")
require(consumed["baselineOfferFocusedID"] == 28029101, "fresh process: consumed fixture baseline wrong")
require(not consumed["showsPrompt"] and consumed.get("visibleCandidateFocusedID") is None, "fresh process: same dismissed checkpoint re-offered")
require(new_offer["baselineOfferFocusedID"] == 28029102, "fresh process: new prior checkpoint baseline wrong")
require(new_offer["showsPrompt"] and new_offer["visibleCandidateFocusedID"] == 28029102, "fresh process: new prior checkpoint was not offered")
if failures:
    print("FAIL: " + str(len(failures)) + " assertion(s)")
    for failure in failures:
        print(" - " + failure)
    sys.exit(1)
print("PASS: five isolated runs; dismiss, restore success/failure, 1s/3s tab frames, lifecycle readback, and independent seeded cold-process fixtures")
