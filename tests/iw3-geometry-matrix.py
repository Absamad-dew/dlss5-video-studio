"""Pure arithmetic fixtures for the WPF/Python parity check. No torch or GPU."""
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
import iw3_worker as worker

sys.stdout.reconfigure(encoding='utf-8')
root=Path(__file__).resolve().parents[1]
cases=[]
for width,height in [(3840,1632),(2160,3840),(1920,1080),(1919,1079),(4096,4096),(9000,2160),(2,2)]:
    for mode in ['Source','2160p','1440p','1080p','720p','540p']:
        for layout in ['FullSBS','HalfSBS','FullOU','HalfOU']:
            for cap,ipd,codec in [(0,0,'H265'),(1024,1.3,'H265'),(1025,-10,'H264')]:
                settings=worker.validate_settings(root,dict(layout=layout,ipd_offset=ipd,
                    inpaint_max_width=cap,method='mlbw_l2_inpaint' if cap else 'row_flow_v3'))
                cases.append(dict(width=width,height=height,mode=mode,codec=codec,settings=settings,
                                  expected=worker.plan_geometry(width,height,settings,mode,codec)))
print(json.dumps(cases,ensure_ascii=False))
