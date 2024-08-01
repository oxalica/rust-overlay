#!/usr/bin/env python
import json
import urllib3
from typing import Any

# Ref: https://rust-lang.zulipchat.com/#narrow/stream/318791-t-crates-io/topic/cargo.20version.20usage/near/401415815
URL = 'https://p.datadoghq.com/dashboard/shared_widget_update/3a172e20-e9e1-11ed-80e3-da7ad0900002-973f4c1011257befa8598303217bfe3a/355142551708710?preferred_time_frame=1mo'
THRESHOLD = (1, 68, 0) # -> 0.0014751846373960305

def main():
    req = urllib3.request('GET', URL)
    raw_json = json.loads(req.data)
    raw: Any = raw_json['responses']['355142551708710'][0]['data'][0]['attributes']
    data: list[tuple[str, int]] = list(
        filter(
            lambda el: el[1] != 0,
            zip(
                (g['group_tags'][0].removeprefix('cargo.version:') for g in raw['series']),
                (sum(x for x in xs if x is not None) for xs in raw['values'])
            ),
        ),
    )
    data.sort(key = lambda el: el[1], reverse = True)
    total = sum(cnt for _, cnt in data)

    old_nightly = 0
    for ver, cnt in data:
        if ver.endswith('-nightly') or ver.endswith('-beta'):
            ver_num = ver.split('-')[0]
            vers_tup = tuple(map(int, ver_num.split('.')))
            if vers_tup <= THRESHOLD:
                old_nightly += cnt
                print(ver, cnt / total)

    print(f'total: {total}')
    print(f'nightly <= {THRESHOLD}: {old_nightly / total}')

if __name__ == '__main__':
    main()
