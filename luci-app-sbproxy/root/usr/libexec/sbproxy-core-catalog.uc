#!/usr/bin/ucode
// Parse GitHub metadata as records: missing fields must never shift the
// association between asset names, download URLs and hashes.
import { readfile } from 'fs';

const releases = json(readfile(ARGV[0]));
const arch = ARGV[1];
const legacy = ARGV[2] === 'legacy';
if (!(arch in ['arm64', 'amd64']))
	exit(2);
// The repository was renamed; accept only these two GitHub-owned aliases.
const repositories = [
	'https://github.com/welenwho/packages/releases/download/',
	'https://github.com/welenwho/SBProxy/releases/download/'
];
for (let release in (type(releases) === 'array' ? releases : [releases])) {
	if (release.draft)
		continue;
	const tag = release.tag_name || '';
	const version = match(tag, /^sbproxy-core-v([0-9]+\.[0-9]+\.[0-9]+(-alpha\.[1-9][0-9]*)?)(-r[1-9][0-9]*)?$/);
	if (!version && !(legacy && tag === 'apk-packages-' + arch))
		continue;
	if (!!release.prerelease !== !!(version && match(version[1], /-alpha\./)))
		continue;
	for (let asset in release.assets || []) {
		let name = asset.name || '';
		if (version) {
			const package_version = version[1] + (version[3] || '');
			if (name !== `sing-box-${package_version}-${arch}.apk`)
				continue;
			name = `sing-box-${package_version}.apk`;
		}
		if (legacy) {
			const alpha = match(name, /_alpha([1-9][0-9]*)/);
			if (alpha) name = replace(name, alpha[0], '-alpha.' + alpha[1]);
		}
		const parsed = match(name, /^sing-box-([0-9]+)\.([0-9]+)\.([0-9]+)(-alpha\.[1-9][0-9]*)?(-r[1-9][0-9]*)?\.apk$/);
		// 1.14 is the minimum supported SBProxy configuration schema.
		if (!parsed || int(parsed[1]) < 1 || (int(parsed[1]) === 1 && int(parsed[2]) < 14))
			continue;
		const url = asset.browser_download_url || '';
		const digest = asset.digest || '';
		if (!length(filter(repositories, repository => url === repository + tag + '/' + asset.name)) ||
		    !match(digest, /^sha256:[0-9a-f]{64}$/) ||
		    type(asset.size) !== 'int' || asset.size <= 0 || asset.size > 268435456)
			continue;
		printf('%s\t%s\t%s\t%d\t%s\n', name, url, digest, asset.size,
		       replace(asset.created_at || '', /[\t\r\n]/g, ''));
	}
}
