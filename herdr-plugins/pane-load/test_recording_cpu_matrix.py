import json
from pathlib import Path
import tempfile
import unittest

from recording_cpu_matrix import (LAYOUTS, INTEGER_CODECS, bundle, verify_bundle,
                                  restore_native, retain_endpoints, load_series)


class CpuMatrixTests(unittest.TestCase):
    def test_restoration_is_exact_and_rejects_ambiguous_timebase(self):
        for raw in range(10000):
            self.assertEqual(restore_native(raw*125//3,125,3),raw)
        with self.assertRaises(ValueError):
            restore_native(1,1,2)
        with self.assertRaises(ValueError):
            restore_native(1,125,3)

    def test_retention_preserves_singletons_endpoints_and_increment(self):
        source={1:[(0,130,0),(1,190,100000000),(2,300,200000000),(3,390,300000000)],
                2:[(1,15,100000000)]}
        for stride in [1,10]:
            retained=retain_endpoints(source,stride)
            self.assertEqual(sum(c[-1]-c[0] for c,_ in retained),260)
            self.assertEqual(retained[1],([15],[100000000]))
            for layout in LAYOUTS:
                for codec in INTEGER_CODECS:
                    for exact in [False,True]:
                        data,accounted=bundle(retained,24000,1000000,layout,codec,exact)
                        verify_bundle(data,retained)
                        self.assertEqual(accounted,260 if exact else 0)
                        with self.assertRaises(ValueError):
                            verify_bundle(data+b'x',retained)

    def test_too_coarse_time_quantum_is_explicitly_rejected(self):
        with self.assertRaisesRegex(ValueError,'collapses retained'):
            bundle([([0,1],[0,100])],1,1000,'columns','uvarint',True)

    def test_loader_rejects_hidden_counter_reset_before_retention(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'capture.jsonl'
            for parts in ([(5,0),(3,0),(10,0)], [(5,5),(3,8),(10,8)]):
                rows=[{'probe_capture':1,'hz':10}]
                for seq,(user,system) in enumerate(parts):
                    rows.append({'seq':seq,'scan_start_ns':seq*100000000,
                                 'processes':[[10,1,0,0,'fixture',user,system,0]]})
                path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
                with self.assertRaisesRegex(ValueError,'counter reset'):
                    load_series(path,1,1)


if __name__=='__main__':
    unittest.main()
