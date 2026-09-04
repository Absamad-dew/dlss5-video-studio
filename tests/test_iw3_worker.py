import importlib.util
from pathlib import Path
import unittest
import tempfile
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python'))
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
            plan=worker.plan_geometry(1920,1080,s,'2160p','H265')
            cli=worker.build_cli(s,'a','b','H265',18,25,plan)
            flags=set(cli)&{'--half-sbs','--half-tb','--tb'}
            self.assertEqual(flags, {flag} if flag else set())
            self.assertNotIn('--max-output-height',cli)
            self.assertIn('scale=3840:2160:flags=lanczos',cli)

    def test_ultrawide_4k_does_not_become_10k_sbs(self):
        p=worker.plan_geometry(3840,1632,self.values,'2160p')
        self.assertEqual(p['input_geometry'],[3840,1632])
        self.assertEqual(p['output_geometry'],[7680,1632])
        self.assertTrue(p['valid'])
        self.assertIsNone(p['video_filter'])
        self.assertNotIn('--vf',worker.build_cli(self.values,'a','b','H265',18,25,p))

    def test_portrait_square_and_wide_fit_inside_oriented_box(self):
        for source,eye in [((1080,1920),(2160,3840)),((4096,4096),(2160,2160)),
                           ((7680,2160),(3840,1080)),((1920,1080),(3840,2160))]:
            with self.subTest(source=source):
                p=worker.plan_geometry(*source,self.values,'2160p')
                self.assertEqual(p['input_geometry'],list(eye))
                self.assertTrue(p['valid'])

    def test_full_half_and_ipd_are_included_in_encoder_guard(self):
        for layout,expected in [('FullSBS',[7680,2160]),('HalfSBS',[3840,2160]),
                                ('FullOU',[3840,4320]),('HalfOU',[3840,2160])]:
            s=dict(self.values,layout=layout)
            self.assertEqual(worker.plan_geometry(3840,2160,s)['output_geometry'],expected)
        p=worker.plan_geometry(3840,2160,dict(self.values,ipd_offset=10))
        self.assertEqual(p['output_geometry'],[9984,2160])
        self.assertFalse(p['valid'])
        with self.assertRaisesRegex(ValueError,'9984.*8192'):worker.require_geometry(p)

    def test_source_not_silently_capped_and_hevc_limits_checked(self):
        p=worker.plan_geometry(5082,2160,self.values)
        self.assertEqual(p['input_geometry'],[5082,2160])
        self.assertEqual(p['output_geometry'],[10164,2160])
        with self.assertRaisesRegex(ValueError,'10164.*8192'):worker.require_geometry(p)
        p=worker.plan_geometry(4096,2160,self.values)
        self.assertTrue(p['valid'])  # Exactly 8192 is permitted.
        self.assertFalse(worker.plan_geometry(4098,2160,self.values)['valid'])
        self.assertFalse(worker.plan_geometry(3840,2160,self.values,codec='H264')['valid'])

    def test_inpaint_rounding_matches_upstream_and_is_explicit(self):
        s=dict(self.values,method='mlbw_l2_inpaint',inpaint_max_width=1024)
        p=worker.plan_geometry(3840,1632,s)
        self.assertEqual(p['content_eye_geometry'],[1024,436])
        self.assertEqual(p['output_geometry'],[2048,436])
        # The geometry settings never modify the user's selected depth settings.
        self.assertEqual(s['resolution'],self.values['resolution'])

    def test_odd_output_is_rejected_without_silent_crop(self):
        p=worker.plan_geometry(1919,1079,self.values)
        self.assertEqual(p['source_geometry'],[1919,1079])
        self.assertFalse(p['valid'])
        self.assertTrue(worker.plan_geometry(1919,1079,self.values,'1080p')['valid'])

    def test_transport_limit_checked_even_when_final_output_fits(self):
        p=worker.plan_geometry(10000,2000,self.values,'2160p')
        self.assertTrue(p['valid'])
        with self.assertRaisesRegex(ValueError,'8192'):worker.require_geometry(p,prepare=True)
        with self.assertRaisesRegex(ValueError,'8192'):worker.require_geometry(p,dlss=True)

    def test_invalid_geometry_fails_before_workdir_dlss_or_model(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'result.mp4'
            args=SimpleNamespace(root=ROOT,settings=None,codec='H265',input='input.mp4',network=None,
                                 start=0,frames=0,output=output,output_mode='Source')
            info={'streams':[{'codec_type':'video','width':5082,'height':2160,
                             'avg_frame_rate':'25/1','duration':'10'}],'format':{}}
            with patch.object(worker,'configure_imports'), patch.object(worker,'probe',return_value=info), patch.object(worker,'emit') as emit, \
                 patch.object(worker,'dlss_pass') as dlss, patch.object(worker.tempfile,'mkdtemp') as mkdir:
                with self.assertRaisesRegex(ValueError,'10164.*8192'):worker.main(args)
                dlss.assert_not_called();mkdir.assert_not_called()
                self.assertEqual(emit.call_args[0][0],'STUDIO_IW3_GEOMETRY')
            self.assertFalse(output.exists())

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
