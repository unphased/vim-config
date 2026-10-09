import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import recording_experiment as experiment

from recording_adaptive import adaptive_records
from recording_experiment import (synthetic_rows, chunk_events, _adaptive_sparse_blob,
                                  _check_adaptive_sparse, quantize_summaries,
                                  _quantized_blob, _check_quantized, quantize_rows,
                                  _precision_blob, _check_precision)


class ExperimentTests(unittest.TestCase):
    def test_summaries_split_at_chunk_boundaries_with_exact_coverage(self):
        rows=list(synthetic_rows(30,1,processes=4))
        events=list(adaptive_records(iter(rows)))
        chunks=[rows[n:n+10] for n in range(0,len(rows),10)]
        selected=chunk_events(rows,chunks,events)
        self.assertTrue(any(e['type']=='summary' and e['first_seq']<10<=e['last_seq']
                            for e in events))
        for chunk, group in zip(chunks,selected):
            covered={identity:[] for identity in [(100+i,123,0) for i in range(4)]}
            for event in group:
                if event['type']=='sample':
                    covered[tuple(event['identity'])].append(event['seq'])
                elif event['type']=='summary':
                    self.assertGreaterEqual(event['first_seq'],chunk[0]['seq'])
                    self.assertLessEqual(event['last_seq'],chunk[-1]['seq'])
                    covered[tuple(event['identity'])].extend(range(event['first_seq'],event['last_seq']+1))
            for seqs in covered.values():
                self.assertEqual(sorted(seqs),[r['seq'] for r in chunk])

    def test_sparse_adaptive_chunk_roundtrip_and_independent_checkpoints(self):
        rows=list(synthetic_rows(60,1,processes=4))
        events=list(adaptive_records(iter(rows)))
        chunks=[rows[n:n+10] for n in range(0,len(rows),10)]
        for chunk, group in zip(chunks,chunk_events(rows,chunks,events)):
            blob=_adaptive_sparse_blob(chunk,group)
            _check_adaptive_sparse(blob,chunk,group)

    def test_quantized_summaries_declare_precision_and_preserve_full_samples(self):
        rows=list(synthetic_rows(600,.1,processes=4))
        events=list(adaptive_records(iter(rows)))
        rounded=quantize_summaries(events,10_000_000,256*1024)
        for before, after in zip(events,rounded):
            if before['type']!='summary':
                self.assertEqual(before,after)
            else:
                for key in ('user_ns_start','user_ns_end','system_ns_start','system_ns_end'):
                    self.assertLess(before[key]-after[key],10_000_000)
                    self.assertGreaterEqual(before[key]-after[key],0)
                self.assertLessEqual(after['rss_min_bytes'],before['rss_min_bytes'])
                self.assertGreaterEqual(after['rss_max_bytes'],before['rss_max_bytes'])
                self.assertLess(before['rss_end_bytes']-after['rss_end_bytes'],256*1024)
        blob=_quantized_blob(rows,events,10_000_000,256*1024)
        _check_quantized(blob,rows,events,10_000_000,256*1024)

    def test_explicit_plot_precision_has_bounded_error_and_unchanged_identity(self):
        row={'seq':0,'wall_start_ns':123456789,'scan_start_ns':1234567,'scan_end_ns':1987654,
             'processes':[[10,1,123,456,'worker',12345678,7654321,1234567]]}
        rounded=quantize_rows([row],1_000_000,64*1024,1_000_000)[0]
        self.assertLess(row['wall_start_ns']-rounded['wall_start_ns'],1_000_000)
        self.assertLessEqual(rounded['scan_start_ns'],row['scan_start_ns'])
        self.assertGreaterEqual(rounded['scan_end_ns'],row['scan_end_ns'])
        self.assertEqual(rounded['processes'][0][:5],row['processes'][0][:5])
        for index,unit in [(5,1_000_000),(6,1_000_000),(7,64*1024)]:
            self.assertGreaterEqual(row['processes'][0][index]-rounded['processes'][0][index],0)
            self.assertLess(row['processes'][0][index]-rounded['processes'][0][index],unit)
        self.assertEqual(row['processes'][0][5],12345678)
        events=list(adaptive_records([row]))
        units=(1_000_000,64*1024,1_000_000,10_000_000,256*1024)
        for adaptive in [False,True]:
            data=_precision_blob([row],events,units,adaptive)
            _check_precision(data,[row],events,units,adaptive)

    def test_default_rates_accept_seven_hz_without_native_acquisition(self):
        with patch('sys.argv',['experiment','--synthetic','--seconds','2','--hz','7']), \
                patch.dict(experiment.PROBE,{'private_run':lambda:None}), \
                patch.object(experiment,'compare') as compare:
            experiment.main()
        self.assertEqual([call.args[1] for call in compare.call_args_list],[1,7])

    def test_private_capture_refuses_overwrite_and_replays_same_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'capture'
            argv=['experiment','--synthetic','--seconds','2','--hz','1','--capture-out',str(path)]
            old=os.umask(0o077)
            try:
                with patch('sys.argv',argv), patch.dict(experiment.PROBE,{'private_run':lambda:None}), \
                        patch.object(experiment,'compare') as compare:
                    experiment.main()
                    source=compare.call_args.args[0]
                    self.assertEqual(path.stat().st_mode & 0o777,0o600)
                    with self.assertRaises(FileExistsError):
                        experiment.main()
                with patch('sys.argv',['experiment','--input',str(path)]), \
                        patch.dict(experiment.PROBE,{'private_run':lambda:None}), \
                        patch.object(experiment,'compare') as compare:
                    experiment.main()
                    self.assertEqual(compare.call_args.args[0],source)
            finally:
                os.umask(old)

    def test_reports_effective_inherited_summary_units(self):
        output=io.StringIO()
        identity=lambda *a,**kw:SimpleNamespace(stdout=kw['input'])
        with patch.object(experiment,'CODECS',[('identity',[],[])]), \
                patch.object(experiment.subprocess,'run',identity), contextlib.redirect_stdout(output):
            experiment.compare(list(synthetic_rows(4,1,processes=1)),1,[4],
                precision_cpu_ns=1_000_000,precision_rss_bytes=64*1024,
                precision_time_ns=1_000_000,only_precision=True)
        result=[json.loads(line) for line in output.getvalue().splitlines()]
        adaptive=next(row for row in result if row['layout']=='bounded-precision-adaptive')
        self.assertEqual(adaptive['sample_cpu_unit_ns'],1_000_000)
        self.assertEqual(adaptive['summary_cpu_unit_ns'],1_000_000)
        self.assertEqual(adaptive['summary_rss_unit_bytes'],64*1024)
        self.assertEqual(adaptive['precision_units'][3:],[1_000_000,64*1024])

    def test_high_rate_plateau_has_full_transition_windows_and_sparse_middle(self):
        rows=list(synthetic_rows(600,.1,processes=4))
        stats={}
        events=list(adaptive_records(iter(rows),stats=stats))
        full={e['seq'] for e in events if e['type']=='sample' and e['identity'][0]==100}
        self.assertTrue(set(range(80,121))<=full)
        self.assertTrue(set(range(380,421))<=full)
        self.assertLess(len(full & set(range(150,350))),10)
        self.assertLessEqual(stats['peak_buffered_observations'],4*22)


if __name__=='__main__':
    unittest.main()
