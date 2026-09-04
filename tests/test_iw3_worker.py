import importlib.util
from pathlib import Path
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('iw3_worker', ROOT / 'python/iw3_worker.py')
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


class Iw3SettingsTest(unittest.TestCase):
    def setUp(self):
        self.values = worker.validate_settings(ROOT, {})

    def test_reference_has_no_studio_enhancement(self):
        self.assertEqual(self.values['dlss_mode'], 'Off')
        self.assertEqual(self.values['target_fps'], '0')
        self.assertEqual(self.values['inpaint_max_width'], 0)

    def test_every_method_builds_a_distinct_original_method(self):
        methods = next(x for x in worker.schema(ROOT) if x['key'] == 'method')['options']
        for method in methods:
            with self.subTest(method=method['value']):
                s = worker.validate_settings(ROOT, {'method': method['value']})
                cli = worker.build_cli(s, 'source.mp4', 'out.mp4', 'H265', 18, 60)
                self.assertEqual(cli[cli.index('--method')+1], method['value'])
                self.assertNotIn('--inpaint-max-width', cli)
                self.assertEqual(cli[cli.index('--max-fps')+1], '60')

    def test_zero_and_false_are_not_replaced_by_defaults(self):
        s = worker.validate_settings(ROOT, {'divergence':0,'convergence':0,'edge_x':0,
                                           'scene_detect':False,'ema_normalize':False})
        cli = worker.build_cli(s, 'a', 'b', 'H264', 18, 25)
        self.assertNotIn('--scene-detect', cli)
        self.assertNotIn('--ema-normalize', cli)
        self.assertEqual(cli[cli.index('--convergence')+1], '0')

    def test_formats_are_not_double_squeezed(self):
        for layout, flag in [('FullSBS',None),('HalfSBS','--half-sbs'),('FullOU','--tb'),('HalfOU','--half-tb')]:
            s=worker.validate_settings(ROOT, {'layout':layout})
            cli=worker.build_cli(s,'a','b','H265',18,25,2160)
            flags=set(cli)&{'--half-sbs','--half-tb','--tb'}
            self.assertEqual(flags, {flag} if flag else set())
            self.assertNotIn('--max-output-height',cli)
            self.assertIn('scale=-2:2160:flags=lanczos',cli)

    def test_invalid_values_fail_instead_of_changing_quality(self):
        for values in [{'method':'GAPW'},{'divergence':float('nan')},{'ema_normalize':'false'},
                       {'batch_size':1.5},{'unknown':2},{'divergence':11}]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                worker.validate_settings(ROOT,values)

    def test_all_quality_controls_forward_to_iw3(self):
        s=worker.validate_settings(ROOT,{'resolution':518,'stereo_width':1920,'warp_steps':2,
                                        'mask_inner_dilation':2,'mask_outer_dilation':4,
                                        'depth_aa':True,'tta':True,'low_vram':True,'disable_amp':True})
        cli=worker.build_cli(s,'a','b','H265',18,25)
        for flag in ['--resolution','--stereo-width','--warp-steps','--mask-inner-dilation',
                     '--mask-outer-dilation','--depth-aa','--tta','--low-vram','--disable-amp']:
            self.assertIn(flag,cli)

    def test_publication_preserves_an_existing_user_file(self):
        with tempfile.TemporaryDirectory() as directory:
            ready, output = Path(directory)/'ready', Path(directory)/'user.mp4'
            ready.write_bytes(b'new'); output.write_bytes(b'user')
            with self.assertRaises(FileExistsError):
                worker.publish_file(ready, output)
            self.assertEqual(output.read_bytes(), b'user')
            self.assertEqual(list(Path(directory).glob('*.partial')), [])
            other = Path(directory)/'other.mp4'
            worker.publish_file(ready, other)
            self.assertEqual(other.read_bytes(), b'new')


if __name__=='__main__':
    unittest.main()
