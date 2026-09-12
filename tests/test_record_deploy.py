import json

from ops.record_deploy import format_record, load_deploys, main, record_deploy


def test_record_appends_in_order(tmp_path):
    path = tmp_path / "deploys.json"
    record_deploy(path, "abc123", "ar/xrpld:abc123", False, "denis", date="2026-09-12T10:00:00Z")
    record_deploy(path, "def456", "ar/xrpld:def456", True, "denis", date="2026-09-12T11:00:00Z")
    deploys = json.loads(path.read_text())
    assert [d["sha"] for d in deploys] == ["abc123", "def456"]
    assert deploys[1] == {
        "sha": "def456", "image": "ar/xrpld:def456", "genesis": True,
        "date": "2026-09-12T11:00:00Z", "operator": "denis",
    }


def test_cli_records_and_shows_last(tmp_path, capsys):
    path = tmp_path / "deploys.json"
    path.write_text("[]\n")
    assert main(["--file", str(path), "--sha", "abc", "--image", "img", "--genesis", "0", "--operator", "op"]) == 0
    assert main(["--file", str(path), "--show-last"]) == 0
    out = capsys.readouterr().out
    assert "rolling sha=abc image=img by op" in out
    assert load_deploys(path)[0]["genesis"] is False


def test_cli_requires_sha_and_image(tmp_path):
    assert main(["--file", str(tmp_path / "d.json"), "--sha", "abc"]) == 2


def test_format_record_none():
    assert format_record(None) == "last deploy: none recorded"
