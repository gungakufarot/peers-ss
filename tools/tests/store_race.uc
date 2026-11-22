// usage: ucode store_race.uc <who> <n> ; appends n entries "<who>-i" to test-stage3/race.json
'use strict';
import * as S from '/usr/share/peers-ss/keystore.uc';
import * as ST from '/usr/share/peers-ss/store.uc';
import { kdf } from '/usr/share/peers-ss/crypto.uc';
let who = ARGV[0], n = +ARGV[1], file = ARGV[2] ?? 'test-stage3/race.json';
ST.init('gungakufarot/peers-ss-state', S.get('gh_token'), kdf('stage3-test-password', '00112233445566778899aabbccddeeff', 2000));
let total_conf = 0;
for (let i = 1; i <= n; i++) {
	let r = ST.update(file, (o) => {
		o ??= { entries: [] };
		push(o.entries, who + '-' + i);
		return o;
	}, { message: 'race ' + who + '-' + i });
	total_conf += r.conflicts ?? 0;
	print(sprintf('%s-%d ok=%s attempts=%s\n', who, i, r.ok, r.attempts));
}
print(sprintf('%s conflicts=%d\n', who, total_conf));
