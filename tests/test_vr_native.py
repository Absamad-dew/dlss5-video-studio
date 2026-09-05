"""CPU contracts; GPU equivalence lives in qa_native_vr.py."""
import dataclasses
from pathlib import Path
import sys
import tempfile
import unittest
import numpy as np
import torch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from vr_shared_depth import DepthSample,RawDepthWriter,raw_depth_frames,SharedDepthRuntime
from vr_reconstruction import plan_tiles,grid01,sample,sample_u8,restore_background
from vr_quality_worker import Packet,TemporalReconstructor,native_temporal_depth


class NativeVRTests(unittest.TestCase):
    def test_raw_motion_uses_canonical_shape_and_source_units(self):
        import vr_depth_worker as legacy
        depth=torch.linspace(.2,.8,31)[None,None,None].expand(1,1,18,31)
        previous=depth+.1
        small=np.zeros((6,10),dtype=legacy.MOTION_DTYPE)
        small['dx']=2; small['confidence']=255; small['valid']=1
        result=native_temporal_depth(depth,previous,(small,124,72),.55,{})
        dense=np.zeros((18,31),dtype=legacy.MOTION_DTYPE)
        dense['dx']=2; dense['confidence']=255; dense['valid']=1
        reference=legacy.motion_compensated_depth(depth,previous,dense,124,72,.55,{})
        torch.testing.assert_close(result,reference,atol=1e-7,rtol=0)
        self.assertEqual(result.shape,depth.shape)
        small['confidence']=0
        self.assertTrue(torch.equal(native_temporal_depth(depth,previous,(small,124,72),.55,{}),depth))
        self.assertTrue(torch.equal(native_temporal_depth(depth,None,(small,124,72),.55,{}),depth))

    def test_raw_roundtrip_two_chunks_and_scene_cut(self):
        with tempfile.TemporaryDirectory() as d:
            paths=[]
            for chunk in range(2):
                p=Path(d)/f'chunk-{chunk:04}.vrd';paths.append(p)
                writer=RawDepthWriter(p,2,chunk*2)
                for i in range(2):
                    raw=np.arange(20,dtype=np.float32).reshape(4,5)+chunk+i*.17
                    writer.write(DepthSample(np.zeros((2,2)),raw,'max'),i==0)
                writer.close(True)
            result=list(raw_depth_frames(paths))
            self.assertEqual([v[0] for v in result],[0,1,2,3])
            self.assertEqual([v[2] for v in result],[True,False,True,False])
            np.testing.assert_array_equal(result[3][1],np.arange(20,dtype=np.float32).reshape(4,5)+1+.17)
            self.assertEqual(result[3][3],'max')

    def test_raw_rejects_incomplete_and_bad_timeline(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'chunk-0.vrd';w=RawDepthWriter(p,2,0)
            w.write(DepthSample(None,np.ones((3,4))),False)
            with self.assertRaises(ValueError): w.close(True)
            self.assertFalse(p.exists());self.assertFalse(p.with_suffix('.vrd.partial').exists())
            w=RawDepthWriter(p,1,9);w.write(DepthSample(None,np.ones((3,4))),False);w.close(True)
            with self.assertRaisesRegex(ValueError,'timeline'):list(raw_depth_frames([p]))

    def test_raw_budget_and_finite_validation(self):
        with tempfile.TemporaryDirectory() as d:
            w=RawDepthWriter(Path(d)/'chunk-0.vrd',1,0,limit_bytes=20)
            with self.assertRaises(RuntimeError):w.write(DepthSample(None,np.ones((3,4))),False)
            w.close(False)
            with self.assertRaises(ValueError):w.write(DepthSample(None,np.full((3,4),np.nan)),False)

    def test_raw_full_range_budget_fails_before_publishing(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'chunk-0.vrd'
            # The first 2-frame chunk fits, but the selected 20-frame range does not.
            writer=RawDepthWriter(path,2,0,limit_bytes=512,planned_total=20)
            with self.assertRaisesRegex(RuntimeError,'Select at most'):
                writer.write(DepthSample(None,np.ones((3,4))),False)
            writer.close(False)
            self.assertFalse(path.exists())
            self.assertFalse(path.with_suffix('.vrd.partial').exists())
            writer=RawDepthWriter(path,2,0,limit_bytes=512,planned_total=2)
            for _ in range(2):writer.write(DepthSample(None,np.ones((3,4))),False)
            writer.close(True)
            self.assertEqual(len(list(raw_depth_frames([path]))),2)
            with self.assertRaisesRegex(ValueError,'shorter'):
                RawDepthWriter(path,2,10,planned_total=11)

    def test_tile_coverage_and_phase(self):
        mask=torch.zeros(12,1,514,1030);mask[:,:,12:15,1:5]=1;mask[:,:,390:405,1026:]=1
        ownership=torch.zeros_like(mask[0])
        for core,outer in plan_tiles(mask,256,192):
            a,b,c,d=core;x0,y0,x1,y1=outer
            self.assertEqual(x0%64,0);self.assertEqual(y0%64,0)
            self.assertLessEqual(x0,a);self.assertGreaterEqual(x1,c)
            ownership[:,b:d,a:c]+=1
        self.assertTrue(torch.all(ownership[mask.any(0)]==1))
        self.assertLessEqual(int(ownership.max()),1)
        self.assertEqual(plan_tiles(torch.zeros_like(mask)),[])

    def test_sampling_coordinate_identity(self):
        x=torch.rand(1,3,13,27)
        torch.testing.assert_close(sample(x,grid01(13,27,'cpu')),x,atol=2e-6,rtol=0)

    def test_sparse_uint8_sampler_matches_float_reference(self):
        torch.manual_seed(17)
        image=torch.randint(0,256,(1,3,53,101),dtype=torch.uint8)
        coords=torch.rand(1,2,17,29)*1.2-.1
        torch.testing.assert_close(sample_u8(image,coords),sample(image,coords),atol=.003,rtol=0)

    def test_revealed_background_and_foreground_rejection(self):
        background=torch.full((1,3,40,80),120,dtype=torch.uint8)
        target=background.clone();target[:,:,:,38:42]=230
        depth=torch.full((1,1,40,80),.2);depth[:,:,:,38:42]=.9
        holes=torch.zeros_like(depth,dtype=torch.bool);holes[:,:,15:25,39:41]=True
        coords=grid01(40,80,'cpu');far=torch.full_like(depth,.2)
        seed=target.clone()
        out,residual,accepted=restore_background(seed,holes,target,depth,coords,far,
            background,far,np.eye(3),1.)
        self.assertTrue(bool(accepted.any()))
        self.assertTrue(torch.equal(out[~holes.expand_as(out)],seed[~holes.expand_as(out)]))
        self.assertEqual(int(out[accepted.expand_as(out)].max()),120)
        _,_,bad=restore_background(seed,holes,target,depth,coords,far,
            background,torch.full_like(depth,.9),np.eye(3),1.)
        self.assertFalse(bool(bad.any()))

    def test_temporal_every_length_exact_count_and_no_scene_leaks(self):
        for count in (1,2,5,6,7,11,12,13,18,31):
            output=[]
            worker=TemporalReconstructor(lambda a,b:output.append(int(a[0,0,0])),atlas=False)
            for i in range(count):
                rgb=torch.full((3,4,8),i,dtype=torch.uint8)
                p=Packet(i,rgb,torch.zeros(4,8),[rgb,rgb],[torch.zeros(1,4,8,dtype=torch.bool)]*2,[])
                worker.append(p,cut=i in (7,16))
            worker.flush()
            self.assertEqual(output,list(range(count)))
            self.assertLessEqual(worker.stats['max_queue_frames'],18)
            self.assertFalse(worker.packets)


if __name__=='__main__':unittest.main()
