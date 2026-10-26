#!/usr/bin/ucode
import { readfile } from 'fs';

const release = json(readfile(ARGV[0]));
const arch = ARGV[1];
if (!(arch in ['arm64', 'amd64'])) exit(2);
const tag = 'apk-packages-' + arch;
if (release.draft || release.prerelease || release.tag_name !== tag) exit(1);
const roots = ['https://github.com/welenwho/SBProxy/releases/download/',
               'https://github.com/welenwho/packages/releases/download/'];
let seen = {};
for (let asset in release.assets || []) {
	const name = asset.name || '';
	const parsed = match(name, /^(luci-app-sbproxy|luci-i18n-sbproxy-zh-cn)-([0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*)\.apk$/);
	if (!parsed || seen[name]) continue;
	const url = asset.browser_download_url || '';
	if (!length(filter(roots, root => url === root + tag + '/' + name)) ||
	    !match(asset.digest || '', /^sha256:[0-9a-f]{64}$/) ||
	    type(asset.size) !== 'int' || asset.size <= 0 || asset.size > 268435456)
		continue;
	seen[name] = true;
	printf('%s\t%s\t%s\t%d\t%s\n', name, url, asset.digest, asset.size,
	       replace(asset.created_at || '', /[\t\r\n]/g, ''));
}
