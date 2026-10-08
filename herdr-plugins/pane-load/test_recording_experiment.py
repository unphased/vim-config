import unittest

from recording_adaptive import adaptive_records
from recording_experiment import (synthetic_rows, chunk_events, _adaptive_sparse_blob,
                                  _check_adaptive_sparse, quantize_summaries,
                                  _quantized_blob, _check_quantized)


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
