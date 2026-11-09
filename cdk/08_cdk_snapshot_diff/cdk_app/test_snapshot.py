"""ho08 快照测试：把合成模板钉进 snapshot/ 目录，漂移即红。

约定：
  - snapshot/ho08-stack.template.json 是"已审定的图纸"，提交进仓库
  - UPDATE_SNAPSHOT=1 时显式重录（对应"审阅并接受变更"的流程动作）
  - 比较做语义归一：剔除每次合成都变的字段（CDKMetadata 版本戳等）
"""
import json
import os
import sys
from pathlib import Path

import pytest
from aws_cdk import App
from aws_cdk.assertions import Template

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app import Ho38Stack  # noqa: E402

SNAPSHOT = Path(__file__).resolve().parents[1] / "snapshot" / "ho08-stack.template.json"
# 每次合成都可能漂移、与资源语义无关的字段（记录时也剔除）
VOLATILE_KEYS = ("Metadata",)


@pytest.fixture(scope="module")
def template() -> dict:
    app = App()
    Ho38Stack(app, "ho08-stack")
    tpl = Template.from_stack(app.node.children[0])
    return tpl.to_json()


def normalized(tpl: dict) -> dict:
    return {k: v for k, v in tpl.items() if k not in VOLATILE_KEYS}


def test_template_matches_snapshot(template: dict) -> None:
    if os.environ.get("UPDATE_SNAPSHOT") == "1":
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT.write_text(json.dumps(normalized(template), indent=1, sort_keys=True) + "\n")
        pytest.skip("snapshot updated")   # 显式更新不算"通过"，重跑才算
    assert SNAPSHOT.exists(), f"缺少快照 {SNAPSHOT}"
    recorded = json.loads(SNAPSHOT.read_text())
    diff = _diff(normalized(recorded), normalized(template))
    assert not diff, f"模板漂移 {len(diff)} 处：\n" + "\n".join(diff)


def _diff(a, b, path="$") -> list[str]:
    out = []
    if type(a) is not type(b):
        return [f"{path}: 类型 {type(a).__name__} → {type(b).__name__}"]
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: 新增")
            elif k not in b:
                out.append(f"{path}.{k}: 丢失")
            else:
                out += _diff(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: 长度 {len(a)} → {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            out += _diff(x, y, f"{path}[{i}]")
    elif a != b:
        out.append(f"{path}: {a!r} → {b!r}")
    return out
