"""Fast CPU-only catalog/readiness/validation checks. No model execution."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python'))
import iw3_da3_install as installer
import iw3_worker as worker
from iw3_da3 import expand_shared_state


class DA3Test(unittest.TestCase):
    def test_only_real_shared_parameters_are_expanded(self):
        shared,distinct=object(),object()
        class Net:
            def state_dict(self,keep_vars):return {'a':shared,'alias_a':shared,'different':distinct}
        state={'a':object()}
        fixed=expand_shared_state(Net(),state)
        self.assertIs(fixed['alias_a'],state['a'])
        self.assertNotIn('different',fixed)
        self.assertNotIn('alias_a',state)

    def test_catalog_and_ui_are_consistent(self):
        models=installer.catalog(ROOT)['models']
        choices=next(f for f in worker.schema(ROOT) if f['key']=='depth_model')['options']
        ids={x['value'] for x in choices}
        self.assertEqual(len(models),5)
        self.assertEqual(len({m['path'] for m in models}),5)
        self.assertEqual(len({m['sha256'] for m in models}),5)
        for m in models:
            self.assertIn(m['id'],ids)
            self.assertEqual(len(m['sha256']),64)
            self.assertEqual(len(m['revision']),40)
            s=worker.validate_settings(ROOT,{'depth_model':m['id']})
            cli=worker.build_cli(s,'in','out','H265',18,25)
            self.assertEqual(cli[cli.index('--depth-model')+1],m['id'])
            self.assertNotIn('--inpaint-max-width',cli)
        for m in models:
            if 'Large_11' in m['id'] or 'Giant_11' in m['id']:
                self.assertTrue(m['repo'].endswith('-1.1'))

    def test_readiness_requires_complete_weights_and_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            m=dict(installer.catalog(ROOT)['models'][0])
            payload=b'test weights'
            m.update(bytes=len(payload),sha256=hashlib.sha256(payload).hexdigest())
            data=installer.catalog(ROOT);data['models']=[m]
            installer.atomic_json(root/'app/iw3-da3-models.json',data)
            self.assertFalse(installer.ready(root,m['id']))
            weight=root/m['path'];weight.parent.mkdir(parents=True);weight.write_bytes(payload)
            source=data['sources'][m['source']]
            code=root/source['path']/'src/depth_anything_3/model/da3.py'
            code.parent.mkdir(parents=True);code.write_text('#test')
            installer.atomic_json(root/source['path']/'install.json',dict(commit=source['commit'],files=[]))
            installer.atomic_json(root/'models/iw3/da3-status'/(m['id']+'.json'),dict(m,mtime_ns=weight.stat().st_mtime_ns))
            self.assertTrue(installer.ready(root,m['id'],verify=True))
            weight.write_bytes(b'broken')
            self.assertFalse(installer.ready(root,m['id']))

    def test_existing_modified_model_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'user.safetensors';path.write_bytes(b'user')
            with self.assertRaisesRegex(RuntimeError,'Existing file differs'):
                installer.download('https://invalid',path,'0'*64,4)
            self.assertEqual(path.read_bytes(),b'user')

    def test_zero_da3_controls_are_preserved(self):
        s=worker.validate_settings(ROOT,{'da3_depth_shift':0,'da3_sky_strength':0,'da3_microbatch':4})
        self.assertEqual(s['da3_depth_shift'],0)
        self.assertEqual(s['da3_sky_strength'],0)
        self.assertEqual(s['da3_microbatch'],4)
        with self.assertRaises(ValueError):worker.validate_settings(ROOT,{'da3_microbatch':0})


if __name__=='__main__': unittest.main()
