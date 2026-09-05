import argparse
from pathlib import Path
import sys
import cv2
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from vr_shared_depth import raw_depth_frames
from vr_reconstruction import background_link

p=argparse.ArgumentParser();p.add_argument('--video',required=True);p.add_argument('--depth',type=Path,required=True)
a=p.parse_args();cap=cv2.VideoCapture(a.video);frames=[];depths=[]
for i,raw,cut,mode in raw_depth_frames(sorted(a.depth.glob('chunk-*.vrd'))):
    ok,frame=cap.read()
    if not ok:break
    frames.append(cv2.cvtColor(cv2.resize(frame,(640,round(frame.shape[0]*640/frame.shape[1]))),cv2.COLOR_BGR2RGB))
    depths.append(raw/max(raw.max(),1e-8))
cap.release()
for i in range(1,len(frames)):
    link=background_link(frames[i-1],frames[i],depths[i-1],depths[i])
    print(i,link.reason,link.confidence,link.matrix,flush=True)
