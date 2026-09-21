import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

module_path = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/GuestSetup/guest_setup.py'
spec = importlib.util.spec_from_file_location('guest_setup', module_path)
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)

class GuestSetupTests(unittest.TestCase):
    def test_private_write_atomic_permissions_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'token.json'
            guest.private_write(target, 'first')
            guest.private_write(target, 'second')
            self.assertEqual(target.read_text(), 'second')
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            link = Path(folder) / 'link'
            link.symlink_to(target)
            with self.assertRaises(guest.SetupFailure): guest.private_write(link, 'bad')
            self.assertEqual(target.read_text(), 'second')

    def test_configuration_preserves_provider_and_token_on_retry(self):
        import yaml
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as folder:
            hermes = Path(folder) / 'hermes'
            state = Path(folder) / 'state'
            hermes.mkdir()
            (hermes / 'config.yaml').write_text('model:\n  provider: openai-codex\n')
            (hermes / '.env').write_text('EXISTING_SETTING=keep\n')
            with patch.object(guest, 'HERMES', hermes), patch.object(guest, 'STATE', state), patch.object(guest.Path, 'home', return_value=Path(folder)):
                guest.configure()
                first = guest.environment_values((hermes / '.env').read_text())
                guest.configure()
                second = guest.environment_values((hermes / '.env').read_text())
                self.assertEqual(first['API_SERVER_KEY'], second['API_SERVER_KEY'])
                self.assertEqual(second['EXISTING_SETTING'], 'keep')
                self.assertEqual(second['API_SERVER_HOST'], '127.0.0.1')
                config = yaml.safe_load((hermes / 'config.yaml').read_text())
                self.assertEqual(config['model']['provider'], 'openai-codex')
                self.assertEqual(config['platform_toolsets']['api_server'].count('computer_use'), 1)

    def test_tailnet_requires_running_and_exact_dns_hostname(self):
        good = {'BackendState':'Running','Self':{'DNSName':'guest.example.ts.net.'}}
        self.assertEqual(guest.tailnet_endpoint(good), 'https://guest.example.ts.net')
        for bad in ['guest.example.com', 'guest.ts.net.evil.test', 'guest.example.ts.net/path']:
            good['Self']['DNSName'] = bad
            with self.assertRaises(guest.SetupFailure): guest.tailnet_endpoint(good)
        with self.assertRaises(guest.SetupFailure): guest.tailnet_endpoint({'BackendState':'NeedsLogin'})

    def test_serve_rejects_funnel_unrelated_routes_and_nonloopback(self):
        good = {'TCP': {'443': {'HTTPS':True}}, 'Web': {'guest.example.ts.net:443': {'Handlers': {'/': {'Proxy':'http://127.0.0.1:8642'}}}}}
        guest.validate_serve(good, 'https://guest.example.ts.net')
        guest.validate_serve({}, 'https://guest.example.ts.net', allow_empty=True)
        for change in [{'AllowFunnel':{'guest.example.ts.net:443':True}}, {'TCP':{'80':{'HTTP':True}}}, {'Services':{'service':{}}}]:
            bad = {**good, **change}
            with self.assertRaises(guest.SetupFailure): guest.validate_serve(bad, 'https://guest.example.ts.net')
        good['Web']['guest.example.ts.net:443']['Handlers']['/']['Proxy'] = 'http://0.0.0.0:8642'
        with self.assertRaises(guest.SetupFailure): guest.validate_serve(good, 'https://guest.example.ts.net')

    def test_capabilities_require_auth_and_all_phone_features(self):
        data = {'platform':'hermes-agent','auth':{'type':'bearer','required':True},'features':{key:True for key in ['run_submission','run_status','run_events_sse','run_stop']}}
        data['features']['runs_idempotency'] = {'supported':True,'durable':True,'retention_seconds':3600}
        guest.validate_capabilities(data)
        data['features']['runs_idempotency']['durable'] = False
        with self.assertRaises(guest.SetupFailure): guest.validate_capabilities(data)

if __name__ == '__main__': unittest.main()
