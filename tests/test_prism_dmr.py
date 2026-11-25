import importlib.util
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def test_cache_warmup_uses_sdk_catalog_recipe(monkeypatch, tmp_path, capsys):
    spec = importlib.util.spec_from_file_location(
        "prism_dmr", SCRIPTS / "build-prism-dmr.py"
    )
    wrapper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wrapper)
    from types import SimpleNamespace

    entry = {"id": "inkling-2-mini:q4_k_m", "source": "llama_cpp"}
    calls = []
    monkeypatch.setattr(wrapper, "resolve_model_entry", lambda name: entry)
    monkeypatch.setattr(
        wrapper,
        "prepare",
        lambda value: calls.append(value) or {"binary": "/native/llama-server"},
    )
    monkeypatch.setattr(
        wrapper, "settings", lambda _value: SimpleNamespace(accelerator="metal")
    )
    monkeypatch.setattr("sys.argv", ["build-prism-dmr.py", "--backend", "metal"])
    wrapper.main()
    assert calls == [entry]
    assert (
        "Prepared native llama-server /native/llama-server" in capsys.readouterr().out
    )
