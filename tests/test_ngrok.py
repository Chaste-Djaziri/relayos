import pytest

from laptop_bridge import ngrok


def test_validate_domain_and_endpoint():
    assert ngrok.validate_domain("https://Bridge.ngrok.app/") == "bridge.ngrok.app"
    assert ngrok.endpoint_url("bridge.ngrok.app") == "https://bridge.ngrok.app"


@pytest.mark.parametrize("value", ["", "https://example.com/path", "localhost:4040", "bad"])
def test_invalid_domain(value):
    with pytest.raises(ngrok.NgrokError):
        ngrok.validate_domain(value)


def test_process_spec_keeps_token_out_of_arguments():
    spec = ngrok.process_spec("bridge.ngrok.app", "secret", executable="/tmp/ngrok")
    assert spec["arguments"] == ["http", "127.0.0.1:8765", "--domain", "bridge.ngrok.app"]
    assert "secret" not in spec["arguments"]
    assert spec["environment"]["NGROK_AUTHTOKEN"] == "secret"
