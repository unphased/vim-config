import unittest
from fractions import Fraction
from recording_cpu_focus import frame, unframe, loss, worker_window_error
from recording_cpu_matrix import require
from recording_cpu_shared import encode_shared,decode_shared


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
