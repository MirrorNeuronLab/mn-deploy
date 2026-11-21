import importlib.util
from pathlib import Path


def test_cache_warmup_uses_sdk_catalog_recipe(monkeypatch, tmp_path, capsys):
    spec = importlib.util.spec_from_file_location(
        "prism_dmr", Path(__file__).with_name("build-prism-dmr.py")
    )
    wrapper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wrapper)
    entry = {"id": "inkling-2-mini:q4_k_m", "preparation": {"kind": "dmr_native"}}
    calls = []
    monkeypatch.setattr(
        wrapper,
        "resolve_model_entry",
        lambda value: entry if value == "inkling-2-mini" else None,
    )
    monkeypatch.setattr(
        wrapper,
        "prepare_dmr_model",
        lambda value, **kwargs: calls.append((value, kwargs)) or value,
    )
    monkeypatch.setattr(
        wrapper, "managed_descriptor", lambda *args, **kwargs: {"root": tmp_path}
    )
    monkeypatch.setattr("sys.argv", ["build-prism-dmr.py", "--backend", "metal"])
    wrapper.main()
    assert calls == [(entry, {"accelerator": "metal"})]
    assert "mn model add inkling-2-mini --local" in capsys.readouterr().out
