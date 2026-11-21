'use strict';
import * as S from '/usr/share/peers-ss/secrets.uc';
import * as ST from '/usr/share/peers-ss/store.uc';
import { kdf } from '/usr/share/peers-ss/crypto.uc';
ST.init('gungakufarot/peers-ss-state', S.get('gh_token'), kdf('stage3-test-password', '00112233445566778899aabbccddeeff', 2000));
let r = ST.get(ARGV[0] ?? 'test-stage3/race.json');
print(sprintf('%J\n', { ok: r.ok, status: r.status, cached: r.cached, n: length(r.obj?.entries ?? []), entries: sort(r.obj?.entries ?? []) }));
print('github time drift vs local: ', ST.now() - time(), '\n');
