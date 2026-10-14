import unittest
from fractions import Fraction
from recording_cpu_focus import frame, unframe, loss, worker_window_error
from recording_cpu_matrix import require
from recording_cpu_shared import encode_shared,decode_shared
from pathlib import Path
from contextlib import redirect_stdout
from unittest.mock import patch
import tempfile
import json
import io
import recording_cpu_focus as focus


class FocusTests(unittest.TestCase):
    def test_frame_keeps_rss_unit_and_rejects_truncation(self):
        data=frame(b'cpu',b'metadata',24000,4096)
        self.assertEqual(unframe(data),(24000,b'cpu',b'metadata',4096))
        for bad in (data[:-1],data+b'x',b'XXXX'+data[4:]):
            with self.assertRaises(ValueError):unframe(bad)

    def test_loss_verification_uses_exact_native_fraction(self):
        key=(1,0,0)
        raw={key:[(0,0,0),(1,0,1),(2,1,10**15)]}
        reduced={key:[raw[key][0],raw[key][-1]]}
        metrics=loss(raw,reduced)
        self.assertEqual(metrics['max_counter_error_native'],Fraction(1,10**15))
        with self.assertRaises(ValueError):
            require(metrics['max_counter_error_native']<=0,'zero tolerance violated')

    def test_real_shape_driver_restores_rss_and_audits_every_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'capture.jsonl'
            rows=[{'probe_capture':1,'hz':2,'workload':{'pid':1}}]
            for seq in range(4):
                stamp=seq*500000000
                rows.append({'seq':seq,'scan_start_ns':stamp,'scan_end_ns':stamp+1000,
                    'wall_start_ns':1000000000+stamp,
                    'processes':[[1,0,10,0,'fixture',(10+20*seq)*125//3,0,4096]]})
            path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
            output=io.StringIO()
            with patch.object(focus,'CODECS',[('gzip-6',None,None)]), \
                 patch.object(focus,'CASES',[focus.CASES[1],focus.CASES[-2]]),redirect_stdout(output):
                focus.run(path,[1])
            results=[json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(results[0]['rss_exact_unit_bytes'],4096)
            for result in results[1:]:
                self.assertIsNotNone(result['controlled_worker_max_1s_error_pp'])
                self.assertIn('across frame boundaries',result['worker_window_audit_scope'])
                self.assertLessEqual(result['max_counter_error_ms'],result['total_counter_error_bound_ms'])

    def test_worker_audit_crosses_frames_and_missing_windows_are_null(self):
        key=(1,0,0)
        raw={key:[(0,0,0),(1,0,500000000),(2,24000,1000000000),
                  (3,24000,1500000000),(4,24000,2000000000)]}
        # Two independent frames: short individually; full audit covers 1s windows.
        a={key:[raw[key][0],raw[key][2]]}
        b={key:[raw[key][3],raw[key][4]]}
        merged={key:decode_shared(encode_shared(a,layout='points'))[key]+
                    decode_shared(encode_shared(b,layout='points'))[key]}
        self.assertGreater(worker_window_error(raw,merged,1),0)
        self.assertIsNone(worker_window_error({key:raw[key][:2]},{key:raw[key][:2]},1))
        self.assertIsNone(worker_window_error(raw,merged,999))


if __name__=='__main__':unittest.main()
