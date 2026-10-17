/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
'require dom';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require sbproxy as sb';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

/* Diversion helpers start — also exercised by frontend regression tests. */
function normalizeDiversionDomains(value) {
	const content = Array.isArray(value) ? value.join('\n') : String(value || '');
	return Array.from(new Set(content.split(/[\r\n]+/)
		.map((v) => v.trim()).filter((v) => v && !v.startsWith('#'))
		.map((v) => v.toLowerCase().replace(/^\.+|\.+$/g, ''))));
}

function diversionOverlap(groups) {
	const suffixes = new Map(), descendants = new Map(), keywords = [];
	const conflict = (old, group, domain) => ({ first: old.label || old.id, second: group.label || group.id, domain });
	for (const group of groups) {
		if (!group.enabled) continue;
		for (const value of normalizeDiversionDomains(group.domains)) {
			if (value.includes('.')) {
				const child = descendants.get(value);
				if (child && child.id !== group.id) return conflict(child, group, value);
				const parts = value.split('.');
				for (let i = 0; i < parts.length; i++) {
					const parent = parts.slice(i).join('.');
					const old = suffixes.get(parent);
					if (old && old.id !== group.id) return conflict(old, group, value);
					if (!descendants.has(parent)) descendants.set(parent, group);
				}
				for (const old of keywords)
					if (old.id !== group.id && value.includes(old.value)) return conflict(old, group, value);
				if (!suffixes.has(value)) suffixes.set(value, group);
			} else {
				for (const [suffix, old] of suffixes)
					if (old.id !== group.id && suffix.includes(value)) return conflict(old, group, value);
				for (const old of keywords)
					if (old.id !== group.id && (value.includes(old.value) || old.value.includes(value))) return conflict(old, group, value);
				keywords.push({ ...group, value });
			}
		}
	}
	return null;
}
/* Diversion helpers end */

const callIngressStatus = rpc.declare({ object: 'luci.sbproxy', method: 'ingress_status', expect: { '': {} } });

function ingressStatusContent(status) {
	const rows = (status.sources || []).map((source) => E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td' }, [source.label]),
		E('td', { 'class': 'td' }, [source.device || '-']),
		E('td', { 'class': 'td' }, [source.online ? _('Online') : (source.present ? _('Offline') : _('Waiting for interface'))])
	]));
	return [
		E('p', {}, [_('Ingress rules: %s').format(status.applied ? _('Applied') : _('Not applied'))]),
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [_('Source'), _('Device'), _('Status')].map((s) => E('th', { 'class': 'th' }, [s]))),
			...rows
		]),
		E('p', {}, [_('Bridge matches: %s; bypassed packets: %s; DNS redirections: %s').format(status.bridge_packets || 0, status.bypassed_packets || 0, status.dns_redirections || 0)]),
		E('p', { 'class': 'cbi-section-descr' }, [_('Counters cover packets seen by nftables; hardware-offloaded packets may not be counted.')]),
		E('p', {}, [_('Last applied: %s').format(status.last_applied ? new Date(status.last_applied * 1000).toLocaleString() : '-')]),
		status.error || status.last_error ? E('p', { 'class': 'alert-message warning' }, [status.error || status.last_error]) : ''
	];
}

const callReadDomainList = rpc.declare({
	object: 'luci.sbproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.sbproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

function normalizeDomainList(value) {
	value = (value || '').trim().replace(/\r\n?/g, '\n');
	return value ? value + '\n' : '';
}

function writeDomainList(type, checksumOption, value) {
	const content = normalizeDomainList(value);

	return callWriteDomainList(type, content).then((result) => {
		if (!result.result)
			throw new Error(_('Failed to save domain list.'));
		uci.set('sbproxy', 'control', checksumOption, sb.calcStringMD5(content));
		return result;
	});
}

const callCurrentNode = rpc.declare({
	object: 'luci.sbproxy',
	method: 'current_node_get',
	expect: { '': {} }
});

function proxyModeDepends(option, extra, modes) {
	for (const mode of modes || ['bypass_mainland_china', 'custom', 'global'])
		option.depends(Object.assign({ routing_mode: mode }, extra || {}));
}

function renderStatus(isRunning, version, currentNode) {
	let spanTemp = '<em><span style="color:%s"><strong>%s (sing-box v%s) %s</strong></span></em>';
	let renderHTML;
	let statusColor = isRunning ? 'green' : 'red';
	let nodeColor = '#1e90ff';
	if (isRunning)
		renderHTML = spanTemp.format(statusColor, _('SBProxy'), version, _('RUNNING'));
	else
		renderHTML = spanTemp.format(statusColor, _('SBProxy'), version, _('NOT RUNNING'));

	if (currentNode)
		renderHTML += '<div><em><span style="color:%s"><strong>%s</strong></span></em></div>'.format(nodeColor, '%h'.format(currentNode));

	return renderHTML;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

return view.extend({
	load() {
		const config = uci.load('sbproxy');
		return Promise.all([
			config,
			sb.getBuiltinFeatures(),
			network.getHostHints(),
			uci.load('wireless'),
			config.then(() => uci.get('sbproxy', 'control', 'ingress_enabled') === '1' ? L.resolveDefault(callIngressStatus(), {}) : {})
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		let features = data[1],
		    hosts = data[2]?.hosts,
		    common_routing_ports = uci.get('sbproxy', 'infra', 'common_port') || '';

		/* Cache all configured proxy nodes, they will be called multiple times */
		let proxy_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = res.address || '',
			    nodeport = res.port || '',
			    endpoint = nodeaddr && nodeport ? ((stubValidator.apply('ip6addr', nodeaddr) ?
				String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport) : res['.name'];

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || endpoint);
		});

		/* Keep URLTest subscription choices stable across subscription updates. */
		let subscription_sources = [], seen_subscriptions = {};
		let configured_subscriptions = uci.get(data[0], 'subscription', 'subscription_url');
		configured_subscriptions = Array.isArray(configured_subscriptions) ? configured_subscriptions :
			(configured_subscriptions ? [ configured_subscriptions ] : []);
		for (let suburl of configured_subscriptions) {
			const hash = sb.calcStringMD5(suburl.replace(/#.*$/, ''));
			if (seen_subscriptions[hash])
				continue;
			seen_subscriptions[hash] = true;

			let title = suburl;
			try {
				const url = new URL(suburl);
				if (url.hash) {
					try {
						title = decodeURIComponent(url.hash.slice(1));
					} catch (e) {
						title = url.hash.slice(1);
					}
				} else {
					title = url.hostname;
				}
			} catch (e) { }

			subscription_sources.push({ hash, title });
		}

		m = new form.Map('sbproxy', _('SBProxy'),
			_('The modern ImmortalWrt proxy platform for ARM64/AMD64. — AI Edition'));

		s = m.section(form.TypedSection);
			s.render = function () {
				poll.add(function () {
					return Promise.all([
						L.resolveDefault(sb.getServiceStatus('sing-box-c'), false),
						L.resolveDefault(callCurrentNode(), null)
					]).then((res) => {
					let isRunning = res[0],
					    current = res[1],
					    current_label = null;

					if (current?.proxy_enabled === false)
						current_label = _('Proxy disabled');
					else if (current?.mode === 'urltest') {
						let active = current.active || {};
						let nodeName = (active?.id && active.id !== 'urltest') ? (proxy_nodes[active.id] || active.label || active.id) : _('Invalid node');

						current_label = (current.smart ? _('Smart selection: %s') : _('URLTest: %s')).format(nodeName);
					}

						let view = document.getElementById('service_status');
						if (view)
							view.innerHTML = renderStatus(isRunning, features.version, current_label);

						});
				});

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		}

		s = m.section(form.NamedSection, 'config', 'sbproxy');

		s.tab('routing', _('Routing Settings'));
		s.tab('dashboard', _('Dashboard'));
		s.tab('diversion', _('Rule Diversion'));

		// Always first; never depend on the selected node or proxy mode.
		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Proxy mode'),
			_('Disable proxy traffic handling without stopping enabled Tailscale or server services. Saved nodes and routing rules are retained.'));
		o.value('disabled', _('Off'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('custom', _('Custom routing'));
		o.value('global', _('Global'));
		o.default = 'disabled';
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'routing_port', _('Proxy ports'),
			_('Choose all ports, common ports, or enter a comma-separated custom list. A custom list replaces the common ports.'));
		proxyModeDepends(o);
		o.retain = true;
		o.value('', _('All ports'));
		o.value('common', _('Common ports + additional ports'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.DynamicList, 'routing_port_extra', _('Additional ports'),
			_('Built-in common ports: %s. Add only ports or ranges that are not already listed.').format(
				'<code>%h</code>'.format(common_routing_ports.replace(/,/g, ', '))));
		proxyModeDepends(o, { routing_port: 'common' });
		o.retain = true;
		o.rmempty = true;
		o.validate = function(section_id, value) {
			return !value || stubValidator.apply('port', value) || stubValidator.apply('portrange', value)
				? true : _('Expecting: %s').format(_('valid port value'));
		}

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'),
			_('Disable is retained for compatibility. Use Proxy mode to turn the proxy off while keeping the selected node.'));
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', sb.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('Manually selected nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.rmempty = true;
		o.retain = true;
		o.validate = function(section_id) {
			let value = this.section.formvalue(section_id, 'main_urltest_nodes');
			let subscriptions = this.section.formvalue(section_id, 'main_urltest_subscriptions');
			let hasNodes = Array.isArray(value) ? value.length : !!value;
			let hasSubscriptions = Array.isArray(subscriptions) ? subscriptions.length : !!subscriptions;
			return !section_id || hasNodes || hasSubscriptions
				? true : _('Expecting: %s').format(_('non-empty value'));
		};

		o = s.taboption('routing', sb.CBIEmptySafeMultiValue, 'main_urltest_subscriptions', _('URLTest subscriptions'),
			_('Include all current and future nodes from the selected subscriptions.'));
		for (const source of subscription_sources)
			o.value(source.hash, source.title);
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.rmempty = true;
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_urltest_smart', _('Smart node selection'),
			_('Evaluate multiple HTTPS targets, reliability and jitter every 60 seconds. Switch after sustained improvement, or repeated failures.'));
		o.default = o.disabled;
		o.rmempty = false;
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_urltest_smart_bandwidth', _('Measure download performance'),
			_('Download up to 256 KiB per candidate for the best three candidates every 10 minutes. Uses about 108 MiB per day per group at most, excluding connection overhead.'));
		o.default = o.enabled;
		o.rmempty = false;
		proxyModeDepends(o, { main_node: 'urltest', main_urltest_smart: '1' }, ['bypass_mainland_china', 'global']);
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('URLTest interval'),
			_('URLTest interval in seconds (default: 60). Smart selection uses its own 60-second cycle; large groups may take longer.'));
		o.datatype = 'range(10,86400)';
		o.placeholder = '60';
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds (default: 75).'));
		o.datatype = 'uinteger';
		o.placeholder = '75';
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_urltest_interrupt_exist_connections', _('Interrupt existing connections'),
			_('Interrupt existing connections when the selected outbound has changed.'));
		o.default = o.disabled;
		o.rmempty = false;
		proxyModeDepends(o, { main_node: 'urltest' }, ['bypass_mainland_china', 'global']);
		o.retain = true;

		o = s.taboption('routing', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://dns.cloudflare.com/dns-query', _('Cloudflare Public DNS (DoH)'));
		o.value('https://dns.google/dns-query', _('Google Public DNS (DoH)'));
		o.value('https://dns.quad9.net/dns-query', _('Quad9 Public DNS (DoH)'));
		o.value('https://dns.adguard-dns.com/dns-query', _('AdGuard Public DNS (DoH)'));
		o.value('https://dns.sb/dns-query', _('DNS.SB Public DNS (DoH)'));
		o.value('https://dns.opendns.com/dns-query', _('Cisco Public DNS (DoH)'));
		o.default = 'https://dns.quad9.net/dns-query';
		o.rmempty = false;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://doh-pure.onedns.net/dns-query', _('ThreatBook Public DNS (DoH)'));
		o.value('https://doh.pub/dns-query', _('Tencent Public DNS (DoH)'));
		o.value('https://dns.alidns.com/dns-query', _('AliDNS Public DNS (DoH)'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.default = 'https://dns.alidns.com/dns-query';
		o.rmempty = false;
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.DynamicList, 'tun_route_exclude_ipv4_ips', _('TUN route exclusion IPv4 addresses'),
			_('Destinations excluded from TUN automatic redirect and handled by system routing. Applies to all routing modes.'));
		o.datatype = 'or(ip4addr, cidr4)';
		proxyModeDepends(o);
		o.retain = true;
		o.validate = function(section_id, value) {
			return !value.endsWith('/0') || _('The default route cannot be excluded from TUN redirect.');
		}

		o = s.taboption('routing', form.DynamicList, 'tun_route_exclude_ipv6_ips', _('TUN route exclusion IPv6 addresses'),
			_('Destinations excluded from TUN automatic redirect and handled by system routing. Applies to all routing modes.'));
		o.datatype = 'or(ip6addr, cidr6)';
		proxyModeDepends(o, { ipv6_support: '1' });
		o.retain = true;
		o.validate = function(section_id, value) {
			return !value.endsWith('/0') || _('The default route cannot be excluded from TUN redirect.');
		}

		o = s.taboption('routing', form.Flag, 'tun_route_exclude_tailscale', _('Auto-exclude Tailscale routes'),
			_('Keep active Tailnet addresses and peer subnets on tailscale0. New Tailscale routes are detected when SBProxy reloads; default routes are ignored so exit-node traffic can still use SBProxy rules.'));
		proxyModeDepends(o);
		o.default = o.disabled;
		o.retain = true;
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack.'));
		proxyModeDepends(o);
		if (features.with_gvisor) {
			o.value('mixed', 'Mixed');
			o.value('gvisor', 'gVisor');
		}
		o.value('system', 'System');
		o.default = 'mixed';
		o.rmempty = false;
		o.retain = true;
		o.onchange = function(ev, section_id, value) {
			let desc = ev.target.nextElementSibling;
			if (value === 'mixed')
				desc.innerHTML = _('Mixed <code>System</code> TCP stack and <code>gVisor</code> UDP stack.')
			else if (value === 'gvisor')
				desc.innerHTML = _('Based on Google/gVisor.');
			else if (value === 'system')
				desc.innerHTML = _('Less compatibility and sometimes better performance.');
		}

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		proxyModeDepends(o);
		o.retain = true;
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('dashboard', form.Flag, 'dashboard_enabled', _('Enable dashboard'));
		proxyModeDepends(o);
		o.default = '0';
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'),
			_('A random available port is assigned on first installation.'));
		proxyModeDepends(o, { dashboard_enabled: '1' });
		o.default = '9095';
		o.datatype = 'port';
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
		o.password = true;
		proxyModeDepends(o, { dashboard_enabled: '1' });
		o.description = _('Use a unique random secret of at least 16 characters. Dashboard access is restricted to LAN and explicitly allowed Tailscale interfaces, even when WAN input is allowed.');
		o.validate = function(sectionId, value) {
			return this.section.formvalue(sectionId, 'dashboard_enabled') !== '1' || (value || '').length >= 16 ?
				true : _('Set an API secret of at least 16 characters when the dashboard is enabled.');
		};
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('dashboard', form.Flag, 'dashboard_allow_tailscale', _('Allow dashboard from Tailscale'),
			_('Only enable this when remote dashboard access is required; set an API secret first.'));
		o.default = o.disabled;
		proxyModeDepends(o, { dashboard_enabled: '1' });
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('dashboard', form.Flag, 'dashboard_tls_tailscale', _('Use Tailscale HTTPS certificate'),
			_('Serve the dashboard with a certificate issued for this device by Tailscale. Embedded Tailscale and HTTPS certificates in the Tailnet DNS settings must be enabled, and the dashboard must be opened with the device MagicDNS name.'));
		o.default = o.disabled;
		proxyModeDepends(o, { dashboard_enabled: '1', dashboard_allow_tailscale: '1' });
		o.rmempty = false;
		o.retain = true;
		o.validate = function(section_id, value) {
			if (value !== '1')
				return true;
			if (uci.get('sbproxy', 'tailscale', 'enabled') !== '1')
				return _('Enable embedded Tailscale before using its HTTPS certificate.');
			return this.section.formvalue(section_id, 'dashboard_secret') ? true :
				_('Set an API secret before exposing the dashboard through Tailscale.');
		};

		o = s.taboption('dashboard', form.Value, 'dashboard_tls_name', _('Dashboard MagicDNS name'),
			_('Fully qualified Tailscale DNS name used to request the HTTPS certificate and open the dashboard.'));
		o.datatype = 'hostname';
		proxyModeDepends(o, { dashboard_enabled: '1', dashboard_allow_tailscale: '1', dashboard_tls_tailscale: '1' });
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('dashboard', form.Button, '_open_dashboard', _('sing-box dashboard'));
		o.inputtitle = _('Open dashboard');
		o.inputstyle = 'apply';
		proxyModeDepends(o, { dashboard_enabled: '1' });
		o.onclick = function() {
			let host = uci.get('sbproxy', 'config', 'dashboard_tls_tailscale') === '1' ?
					uci.get('sbproxy', 'config', 'dashboard_tls_name') : window.location.hostname,
			    port = uci.get('sbproxy', 'config', 'dashboard_port') || '9095';
			if (host.includes(':') && !host.startsWith('['))
				host = '[' + host + ']';
			const scheme = uci.get('sbproxy', 'config', 'dashboard_tls_tailscale') === '1' ? 'https://' : 'http://';
			window.open(scheme + host + ':' + port + '/dashboard/', '_blank', 'noopener,noreferrer');
		};

		o = s.taboption('diversion', form.SectionValue, '_domain_groups', form.GridSection, 'domain_route', _('Diversion groups'),
			_('Mainland whitelist only. Groups are evaluated in order before domain lists and geographic rules. Device and ingress bypass policies still take priority; custom routing is unchanged.'));
		o.depends('routing_mode', 'bypass_mainland_china');
		const groups = o.subsection;
		o.retain = true;
		groups.anonymous = true;
		groups.addremove = true;
		groups.sortable = true;
		groups.tab('general', _('General Settings'));
		groups.tab('domains', _('Domain matching'));
		groups.tab('addresses', _('Address matching'));
		groups.tab('ports', _('Port matching'));
		groups.tab('other', _('Other Fields'));
		let go = groups.taboption('general', form.Flag, 'enabled', _('Enable'));
		go.default = go.enabled;
		go.rmempty = false;
		go = groups.taboption('general', form.Value, 'label', _('Name'));
		go.rmempty = false;
		go = groups.taboption('general', form.ListValue, 'node', _('Target'));
		go.value('_main', _('Main node / URLTest'));
		go.value('_direct', _('Direct'));
		for (const id in proxy_nodes) go.value(id, proxy_nodes[id]);
		uci.sections('sbproxy', 'domain_route', (group) => {
			if (group.node && !['_main', '_direct'].includes(group.node) && !proxy_nodes[group.node])
				go.value(group.node, _('Unavailable node: %s').format(group.node));
		});
		go.default = '_main';
		go.rmempty = false;
		go = groups.taboption('general', form.ListValue, 'missing_node_action', _('When the selected node is unavailable'));
		go.value('error', _('Stop with a configuration error'));
		go.value('reject', _('Reject only this group'));
		go.value('main', _('Use the main node'));
		go.default = 'error';
		go.rmempty = false;
		go.modalonly = true;
		function updateDiversionWarning(section_id, value) {
			const rows = groups.cfgsections().map((id) => ({
				id, label: groups.formvalue(id, 'label') ?? uci.get('sbproxy', id, 'label'),
				enabled: (groups.formvalue(id, 'enabled') ?? uci.get('sbproxy', id, 'enabled')) === '1',
				domains: id === section_id ? value : (groups.formvalue(id, 'domains') ?? uci.get('sbproxy', id, 'domains'))
			}));
			const overlap = diversionOverlap(rows);
			const message = overlap ? _('Overlap at %s: %s takes priority over %s.').format(overlap.domain, overlap.first, overlap.second) :
				_('No overlapping groups detected.');
			for (const el of document.querySelectorAll('[data-sbproxy-diversion-warning]')) {
				el.textContent = message;
				el.className = overlap ? 'alert-message warning' : 'cbi-section-descr';
			}
			return message;
		}
		let warning = groups.taboption('domains', form.DummyValue, '_diversion_warning', _('Group overlap'),
			_('This check covers the quick domain lists only. Rule sets, regular expressions and other constraints can also overlap; the first matching group wins.'));
		warning.modalonly = true;
		warning.renderWidget = function() {
			return E('div', { 'data-sbproxy-diversion-warning': '', 'class': 'cbi-section-descr' }, [updateDiversionWarning()]);
		};
		go = groups.taboption('domains', form.TextValue, 'domains', _('Domain List'),
			_('One domain per line. Dotted entries match domain suffixes; other entries match keywords. Comments beginning with # are ignored. Overlapping groups are allowed: the first match wins and a warning is logged.'));
		go.rows = 10;
		go.monospace = true;
		go.modalonly = true;

		go.cfgvalue = function(section_id) {
			return L.toArray(uci.get('sbproxy', section_id, 'domains')).join('\n');
		};
		go.write = function(section_id, value) { uci.set('sbproxy', section_id, 'domains', normalizeDiversionDomains(value)); };
		go.validate = function(section_id, value) {
			if (this.section.formvalue(section_id, 'enabled') !== '1') return true;
			updateDiversionWarning(section_id, value);
			for (const d of normalizeDiversionDomains(value))
				if (!d || !stubValidator.apply('hostname', d)) return _('Invalid domain entry: %s').format(d);
			return true;
		};


		go = groups.taboption('general', form.DummyValue, '_match_logic', _('Matching logic'));
		go.modalonly = true;
		go.cfgvalue = () => _('Uses the same matching logic as routing rules. Destination selectors share a matching category; ports, source addresses and other conditions constrain it. Empty groups are ignored. Only pure domain groups automatically select a DNS outbound; connection and rule-set groups keep the existing DNS policy.');
		go = groups.taboption('other', sb.CBIStaticList, 'rule_set', _('Rule set'), _('Match one or more enabled rule sets. Manage them in the Rule Set tab.'));
		go.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;
			this.value('builtin:geoip-cn', _('China IP rules (IPv4 and IPv6)'));
			this.value('builtin:geosite-cn', _('China domain rules'));
			uci.sections(data[0], 'ruleset', (set) => { if (set.enabled === '1') this.value(set['.name'], set.label || set['.name']); });
			return this.super('load', section_id);
		};
		go.validate = function(section_id, value) {
			if (!section_id || !value || this.section.formvalue(section_id, 'enabled') !== '1' ||
			    ['builtin:geoip-cn', 'builtin:geosite-cn'].includes(value)) return true;
			const enabled = this.map.lookupOption('enabled', value)?.[0]?.formvalue(value) ?? uci.get('sbproxy', value, 'enabled');
			return uci.get('sbproxy', value) === 'ruleset' && enabled === '1' ? true :
				_('Rule set is missing or disabled: %s').format(value);
		};
		go.modalonly = true;
		go = groups.taboption('other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'));
		go.modalonly = true;
		go = groups.taboption('other', form.ListValue, 'network', _('Network'));
		go.value('', _('Both')); go.value('tcp', _('TCP')); go.value('udp', _('UDP'));
		go.modalonly = true;
		go = groups.taboption('other', form.ListValue, 'ip_version', _('IP version'));
		go.value('', _('Both')); go.value('4', _('IPv4')); go.value('6', _('IPv6'));
		go.modalonly = true;
		go = groups.taboption('other', sb.CBIStaticList, 'protocol', _('Protocol'));
		for (const protocol of ['http', 'tls', 'quic', 'dns', 'ssh', 'bittorrent', 'stun']) go.value(protocol);
		go.modalonly = true;
		go = groups.taboption('other', form.Flag, 'invert', _('Invert'), _('Invert the complete group match, not individual fields.'));
		go.modalonly = true;
		go = groups.taboption('domains', form.DynamicList, 'domain', _('Domains'), _('Match full domain.'));
		go.datatype = 'hostname'; go.modalonly = true;
		go = groups.taboption('domains', form.DynamicList, 'domain_suffix', _('Domain suffix'), _('Match domain suffix.'));
		go.datatype = 'hostname'; go.modalonly = true;
		go = groups.taboption('domains', form.DynamicList, 'domain_keyword', _('Domain keyword'), _('Match domain using keyword.'));
		go.modalonly = true;
		go = groups.taboption('domains', form.DynamicList, 'domain_regex', _('Domain regex'), _('Match domain using regular expression.'));
		go.modalonly = true;
		for (const field of ['ip_cidr', 'source_ip_cidr']) {
			go = groups.taboption('addresses', form.DynamicList, field, field === 'ip_cidr' ? _('IP CIDR') : _('Source IP CIDR'));
			go.datatype = 'or(cidr, ipaddr)'; go.modalonly = true;
		}
		go = groups.taboption('addresses', form.Flag, 'ip_is_private', _('Match private IP'));
		go.modalonly = true;
		go = groups.taboption('addresses', form.Flag, 'source_ip_is_private', _('Match private source IP'));
		go.modalonly = true;
		for (const field of ['port', 'source_port']) {
			go = groups.taboption('ports', form.DynamicList, field, field === 'port' ? _('Port') : _('Source port'));
			go.datatype = 'port'; go.modalonly = true;
		}
		for (const field of ['port_range', 'source_port_range']) {
			go = groups.taboption('ports', form.DynamicList, field, field === 'port_range' ? _('Port range') : _('Source port range'),
				_('Match port range. Format as START:/:END/START:END.'));
			go.validate = sb.validatePortRange; go.modalonly = true;
		}

		/* Custom routing settings start */
		/* Routing settings start */
		o = s.taboption('routing', form.SectionValue, '_routing', form.NamedSection, 'routing', 'sbproxy');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		so = ss.option(form.Value, 'udp_timeout', _('UDP NAT expiration time'),
			_('In seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '300';

		so = ss.option(form.Flag, 'bypass_cn_traffic', _('Bypass CN traffic'),
			_('Bypass mainland China traffic using sing-box routing rules.'));
		so.rmempty = false;

		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
			_('If set, the requested domain name will be resolved to IP before routing.'));
		for (let i in sb.dns_strategy)
			so.value(i, sb.dns_strategy[i]);

		so = ss.option(form.ListValue, 'default_outbound', _('Default outbound'),
			_('Default outbound for connections not matched by any routing rules.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('nil', _('Disable (the service)'));
			this.value('direct-out', _('Direct'));
			this.value('reject', _('Reject'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'nil';
		so.rmempty = false;

		so = ss.option(form.ListValue, 'default_outbound_dns', _('Default outbound DNS'),
			_('Default DNS server for resolving domain name in the server address.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'default-dns';
		so.rmempty = false;
		/* Routing settings end */

		/* Routing nodes start */
		s.tab('routing_node', _('Routing Nodes'));
		o = s.taboption('routing_node', form.SectionValue, '_routing_node', form.GridSection, 'routing_node');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(sb.loadModalTitle, this, _('Routing Node'), _('Add a routing node'), data[0]);
		ss.sectiontitle = L.bind(sb.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(sb.renderSectionAdd, this, ss);

		so = ss.option(form.Value, 'label', _('Label'));
		so.load = L.bind(sb.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'routing_node', 'label');
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'node', _('Node'),
			_('Outbound node'));
		so.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'routing_node', 'node');
		so.editable = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('The tag of the upstream outbound.<br/>Other dial fields will be ignored when enabled.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res['.name'] !== section_id && res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let node = this.section.formvalue(section_id, 'node');

				let conflict = false;
				uci.sections(data[0], 'routing_node', (res) => {
					if (res['.name'] !== section_id) {
						if (res.outbound === section_id && res['.name'] == value)
							conflict = true;
						else if (res.node === 'urltest' && res.urltest_nodes?.includes(node) && res['.name'] == value)
							conflict = true;
					}
				});
				if (conflict)
					return _('Recursive outbound detected!');
			}

			return true;
		}
		so.depends({'node': 'urltest', '!reverse': true});
		so.editable = true;

		so = ss.option(sb.CBIStaticList, 'urltest_nodes', _('URLTest nodes'),
			_('Manually selected nodes to test.'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.depends('node', 'urltest');
		so.rmempty = true;
		so.validate = function(section_id) {
			let value = this.section.formvalue(section_id, 'urltest_nodes');
			let subscriptions = this.section.formvalue(section_id, 'urltest_subscriptions');
			let hasNodes = Array.isArray(value) ? value.length : !!value;
			let hasSubscriptions = Array.isArray(subscriptions) ? subscriptions.length : !!subscriptions;
			if (section_id && !hasNodes && !hasSubscriptions)
				return _('Expecting: %s').format(_('non-empty value'));

			return true;
		}
		so.modalonly = true;

		so = ss.option(sb.CBIEmptySafeMultiValue, 'urltest_subscriptions', _('URLTest subscriptions'),
			_('Include all current and future nodes from the selected subscriptions.'));
		for (const source of subscription_sources)
			so.value(source.hash, source.title);
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Flag, 'urltest_smart', _('Smart node selection'),
			_('Evaluate multiple HTTPS targets, reliability and jitter every 60 seconds. Switch after sustained improvement, or repeated failures.'));
		so.default = so.disabled;
		so.rmempty = false;
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Flag, 'urltest_smart_bandwidth', _('Measure download performance'),
			_('Download up to 256 KiB per candidate for the best three candidates every 10 minutes. Uses about 108 MiB per day per group at most, excluding connection overhead.'));
		so.default = so.enabled;
		so.rmempty = false;
		so.depends({node: 'urltest', urltest_smart: '1'});
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_url', _('Test URL'),
			_('The URL to test.'));
		so.placeholder = 'https://www.gstatic.com/generate_204';
		so.validate = function(section_id, value) {
			if (section_id && value) {
				try {
					let url = new URL(value);
					if (!url.hostname)
						return _('Expecting: %s').format(_('valid URL'));
				}
				catch(e) {
					return _('Expecting: %s').format(_('valid URL'));
				}
			}

			return true;
		}
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_interval', _('URLTest interval'),
			_('URLTest interval in seconds (default: 60). Smart selection uses its own 60-second cycle; large groups may take longer.'));
		so.datatype = 'range(10,86400)';
		so.placeholder = '60';
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let idle_timeout = this.section.formvalue(section_id, 'urltest_idle_timeout') || '1800';
				if (parseInt(value) > parseInt(idle_timeout))
					return _('Test interval must be less or equal than idle timeout.');
			}

			return true;
		}
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds (default: 75).'));
		so.datatype = 'uinteger';
		so.placeholder = '75';
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_idle_timeout', _('Idle timeout'),
			_('The idle timeout in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '1800';
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Flag, 'urltest_interrupt_exist_connections', _('Interrupt existing connections'),
			_('Interrupt existing connections when the selected outbound has changed.'));
		so.default = so.disabled;
		so.rmempty = false;
		so.depends('node', 'urltest');
		so.modalonly = true;
		/* Routing nodes end */

		/* Routing rules start */
		s.tab('routing_rule', _('Routing Rules'));
		o = s.taboption('routing_rule', form.SectionValue, '_routing_rule', form.GridSection, 'routing_rule');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(sb.loadModalTitle, this, _('Routing Rule'), _('Add a routing rule'), data[0]);
		ss.sectiontitle = L.bind(sb.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(sb.renderSectionAdd, this, ss);

		ss.tab('field_other', _('Other Fields'));
		ss.tab('field_host', _('Host/IP Fields'));
		ss.tab('field_port', _('Port Fields'));
		ss.tab('fields_process', _('Process Fields'));

		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
		so.load = L.bind(sb.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'routing_rule', 'label');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
			_('The default rule uses the following matching logic:<br/>' +
			'<code>(domain || domain_suffix || domain_keyword || domain_regex || ip_cidr || ip_is_private)</code> &&<br/>' +
			'<code>(port || port_range)</code> &&<br/>' +
			'<code>(source_ip_cidr || source_ip_is_private)</code> &&<br/>' +
			'<code>source_mac_address</code> &&<br/>' +
			'<code>(source_port || source_port_range)</code> &&<br/>' +
			'<code>other fields</code>.<br/>' +
			'Additionally, included rule sets can be considered merged rather than as a single rule sub-item.'));
		so.value('default', _('Default'));
		so.default = 'default';
		so.rmempty = false;
		so.readonly = true;

		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'),
			_('4 or 6. Not limited if empty.'));
		so.value('4', _('IPv4'));
		so.value('6', _('IPv6'));
		so.value('', _('Both'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
		so.value('bittorrent', _('BitTorrent'));
		so.value('dns', _('DNS'));
		so.value('dtls', _('DTLS'));
		so.value('http', _('HTTP'));
		so.value('quic', _('QUIC'));
		so.value('rdp', _('RDP'));
		so.value('ssh', _('SSH'));
		so.value('stun', _('STUN'));
		so.value('tls', _('TLS'));

		so = ss.taboption('field_other', form.Value, 'client', _('Client'),
			_('Sniffed client type (QUIC client type or SSH client name).'));
		so.value('chromium', _('Chromium / Cronet'));
		so.value('firefox', _('Firefox / uquic firefox'));
		so.value('quic-go', _('quic-go / uquic chrome'));
		so.value('safari', _('Safari / Apple Network API'));
		so.depends('protocol', 'quic');
		so.depends('protocol', 'ssh');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
		so.value('tcp', _('TCP'));
		so.value('udp', _('UDP'));
		so.value('', _('Both'));

		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
			_('Match user name.'));
		so.modalonly = true;

		so = ss.taboption('field_other', sb.CBIStaticList, 'rule_set', _('Rule set'),
			_('Match rule set.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			uci.sections(data[0], 'ruleset', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
			_('Make IP CIDR in rule set used to match the source IP.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
			_('Invert match result.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
		so.value('route', _('Route'));
		so.value('route-options', _('Route options'));
		so.value('reject', _('Reject'));
		so.value('resolve', _('Resolve'));
		so.default = 'route';
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'outbound', _('Outbound'),
			_('Tag of the target outbound.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.rmempty = false;
		so.depends('action', 'route');
		so.editable = true;

		so = ss.taboption('field_other', form.Value, 'override_address', _('Override address'),
			_('Override the connection destination address.'));
		so.datatype = 'ipaddr';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'override_port', _('Override port'),
			_('Override the connection destination port.'));
		so.datatype = 'port';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'udp_disable_domain_unmapping', _('Disable UDP domain unmapping'),
			_('If enabled, for UDP proxy requests addressed to a domain, the original packet address will be sent in the response instead of the mapped domain.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'udp_connect', _('connect UDP connections'),
			_('If enabled, attempts to connect UDP connection to the destination instead of listen.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'udp_timeout', _('UDP timeout'),
			_('Timeout for UDP connections.<br/>Setting a larger value than the inbound UDP timeout will have no effect.'));
		so.datatype = 'uinteger';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'tls_record_fragment', _('TLS record fragment'),
			_('Fragment TLS handshake into multiple TLS records.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'tls_fragment', _('TLS fragment'),
			_('Fragment TLS handshakes. Due to poor performance, try <code>%s</code> first.').format(
				_('TLS record fragment')));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'tls_fragment_fallback_delay', _('Fragment fallback delay'),
			_('The fallback value in milliseconds used when TLS segmentation cannot automatically determine the wait time.'));
		so.datatype = 'uinteger';
		so.placeholder = '500';
		so.depends('tls_fragment', '1');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'resolve_server', _('DNS server'),
			_('Specifies DNS server tag to use instead of selecting through DNS routing.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Default'));
			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
		so.value('default', _('Reply with TCP RST / ICMP port unreachable'));
		so.value('drop', _('Drop packets'));
		so.depends('action', 'reject');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop packets'),
			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
			_('Method'), _('Drop packets')));
		so.depends('reject_method', 'default');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'resolve_strategy', _('Resolve strategy'),
			_('Domain strategy for resolving the domain names.'));
		for (let i in sb.dns_strategy)
			so.value(i, sb.dns_strategy[i]);
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'resolve_disable_cache', _('Disable DNS cache'),
			_('Disable DNS cache in this query.'));
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'resolve_disable_optimistic_cache', _('Disable optimistic DNS cache'),
			_('Disable optimistic DNS caching in this query.'));
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'resolve_rewrite_ttl', _('Rewrite TTL'),
			_('Rewrite TTL in DNS responses.'));
		so.datatype = 'uinteger';
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'resolve_timeout', _('DNS query timeout'),
			_('Override the DNS query timeout for this lookup, in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '10';
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'resolve_client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domains'),
			_('Match full domain.'));
		so.datatype = 'hostname';
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
			_('Match domain suffix.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
			_('Match domain using keyword.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
			_('Match domain using regular expression.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
			_('Match source IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = fwtool.addMACOption(ss, 'field_host', 'source_mac_address', _('Source MAC addresses'),
			_('Match the originating LAN device by MAC address. Devices behind another router or NAT may not be identifiable.'), hosts);

		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
			_('Match IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'));
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
			_('Match source port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
			_('Match source port range. Format as START:/:END/START:END.'));
		so.validate = sb.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
			_('Match port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
			_('Match port range. Format as START:/:END/START:END.'));
		so.validate = sb.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
			_('Match process name.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
			_('Match process path.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
			_('Match process path using regular expression.'));
		so.modalonly = true;
		/* Routing rules end */

		/* DNS settings start */
		s.tab('dns', _('DNS Settings'));
		o = s.taboption('dns', form.SectionValue, '_dns', form.NamedSection, 'dns', 'sbproxy');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		so = ss.option(form.ListValue, 'default_strategy', _('Default DNS strategy'),
			_('The DNS strategy for resolving the domain name in the address.'));
		for (let i in sb.dns_strategy)
			so.value(i, sb.dns_strategy[i]);

		so = ss.option(form.ListValue, 'default_server', _('Default DNS server'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'default-dns';
		so.rmempty = false;

		so = ss.option(form.Value, 'client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';

		so = ss.option(form.Flag, 'cache_file_store_dns', _('Store DNS cache'),
			_('Persist the complete DNS cache in the cache file.'));
		/* DNS settings end */

		/* DNS servers start */
		s.tab('dns_server', _('DNS Servers'));
		o = s.taboption('dns_server', form.SectionValue, '_dns_server', form.GridSection, 'dns_server');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(sb.loadModalTitle, this, _('DNS Server'), _('Add a DNS server'), data[0]);
		ss.sectiontitle = L.bind(sb.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(sb.renderSectionAdd, this, ss);

		so = ss.option(form.Value, 'label', _('Label'));
		so.load = L.bind(sb.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'dns_server', 'label');
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'type', _('Type'));
		so.value('udp', _('UDP'));
		so.value('tcp', _('TCP'));
		so.value('tls', _('TLS'));
		so.value('https', _('HTTPS'));
		so.value('h3', _('HTTP/3'));
		so.value('quic', _('QUIC'));
		if (features.with_dhcp)
			so.value('dhcp', _('DHCP'));
		so.default = 'udp';
		so.rmempty = false;

		so = ss.option(form.Value, 'server', _('Address'),
			_('The address of the dns server.'));
		so.datatype = 'or(hostname, ipaddr)';
		so.rmempty = false;
		for (const type of [ 'udp', 'tcp', 'tls', 'https', 'h3', 'quic' ])
			so.depends('type', type);

		so = ss.option(widgets.DeviceSelect, 'interface', _('DHCP interface'),
			_('Discover DNS servers dynamically from this interface. Leave empty to use the default interface.'));
		so.multiple = false;
		so.noaliases = true;
		so.depends('type', 'dhcp');
		so.modalonly = true;

		so = ss.option(form.Value, 'server_port', _('Port'),
			_('The port of the DNS server.'));
		so.placeholder = 'auto';
		so.datatype = 'port';
		for (const type of [ 'udp', 'tcp', 'tls', 'https', 'h3', 'quic' ])
			so.depends('type', type);

		so = ss.option(form.Value, 'path', _('Path'),
			_('The path of the DNS server.'));
		so.placeholder = '/dns-query';
		so.depends('type', 'https');
		so.depends('type', 'h3');
		so.modalonly = true;

		so = ss.option(form.DynamicList, 'headers', _('Headers'),
			_('Additional headers to be sent to the DNS server.'));
		so.depends('type', 'https');
		so.depends('type', 'h3');
		so.modalonly = true;

		so = ss.option(form.Value, 'tls_sni', _('TLS SNI'),
			_('Used to verify the hostname on the returned certificates.'));
		so.depends('type', 'tls');
		so.depends('type', 'https');
		so.depends('type', 'h3');
		so.depends('type', 'quic');
		so.modalonly = true;

		so = ss.option(form.ListValue, 'domain_resolver', _('Domain resolver'),
			_('Tag of another DNS server used to resolve a domain name in the server address.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('None'));
			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res['.name'] !== section_id && res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let conflict = false;
				uci.sections(data[0], 'dns_server', (res) => {
					if (res['.name'] !== section_id)
						if (res.domain_resolver === section_id && res['.name'] == value)
							conflict = true;
				});
				if (conflict)
					return _('Recursive resolver detected!');
			}

			return true;
		}
		for (const type of [ 'udp', 'tcp', 'tls', 'https', 'h3', 'quic' ])
			so.depends('type', type);
		so.modalonly = true;

		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
			_('The domain strategy for resolving the domain name in the address.'));
		for (let i in sb.dns_strategy)
			so.value(i, sb.dns_strategy[i]);
		for (const type of [ 'udp', 'tcp', 'tls', 'https', 'h3', 'quic' ])
			so.depends({ type, domain_resolver: '', '!reverse': true });
		so.modalonly = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('Tag of an outbound for connecting to the dns server.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'direct-out';
		so.rmempty = false;
		so.editable = true;
		/* DNS servers end */

		/* DNS rules start */
		s.tab('dns_rule', _('DNS Rules'));
		o = s.taboption('dns_rule', form.SectionValue, '_dns_rule', form.GridSection, 'dns_rule');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(sb.loadModalTitle, this, _('DNS Rule'), _('Add a DNS rule'), data[0]);
		ss.sectiontitle = L.bind(sb.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(sb.renderSectionAdd, this, ss);

		ss.tab('field_other', _('Other Fields'));
		ss.tab('field_host', _('Host/IP Fields'));
		ss.tab('field_port', _('Port Fields'));
		ss.tab('fields_process', _('Process Fields'));

		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
		so.load = L.bind(sb.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'dns_rule', 'label');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
			_('The default rule uses the following matching logic:<br/>' +
			'<code>(domain || domain_suffix || domain_keyword || domain_regex)</code> &&<br/>' +
			'<code>(port || port_range)</code> &&<br/>' +
			'<code>(source_ip_cidr || source_ip_is_private)</code> &&<br/>' +
			'<code>(source_port || source_port_range)</code> &&<br/>' +
			'<code>other fields</code>.<br/>' +
			'Additionally, included rule sets can be considered merged rather than as a single rule sub-item.'));
		so.value('default', _('Default'));
		so.default = 'default';
		so.rmempty = false;
		so.readonly = true;
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'));
		so.value('4', _('IPv4'));
		so.value('6', _('IPv6'));
		so.value('', _('Both'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'query_type', _('Query type'),
			_('Match query type.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
		so.value('tcp', _('TCP'));
		so.value('udp', _('UDP'));
		so.value('', _('Both'));

		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
		so.value('bittorrent', _('BitTorrent'));
		so.value('dtls', _('DTLS'));
		so.value('http', _('HTTP'));
		so.value('quic', _('QUIC'));
		so.value('rdp', _('RDP'));
		so.value('ssh', _('SSH'));
		so.value('stun', _('STUN'));
		so.value('tls', _('TLS'));

		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
			_('Match user name.'));
		so.modalonly = true;

		so = ss.taboption('field_other', sb.CBIStaticList, 'rule_set', _('Rule set'),
			_('Match rule set.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			uci.sections(data[0], 'ruleset', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
			_('Make IP CIDR in rule sets match the source IP.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'match_response', _('Match DNS response'),
			_('Evaluate the query with the selected server before matching response addresses or IP rule sets.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
			_('Invert match result.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
		so.value('route', _('Route'));
		so.value('evaluate', _('Evaluate'));
		so.value('respond', _('Respond'));
		so.value('route-options', _('Route options'));
		so.value('reject', _('Reject'));
		so.value('predefined', _('Predefined'));
		so.default = 'route';
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'server', _('Server'),
			_('Tag of the target dns server.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.rmempty = false;
		so.editable = true;
		so.depends('action', 'route');
		so.depends('action', 'evaluate');

		so = ss.taboption('field_other', form.ListValue, 'evaluate_server', _('Evaluation server'),
			_('DNS server used to obtain the response before response matching.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.depends('match_response', '1');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'dns_disable_cache', _('Disable DNS cache'),
			_('Disable cache and save cache in this query.'));
		so.depends('action', 'route');
		so.depends('action', 'evaluate');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'dns_disable_optimistic_cache', _('Disable optimistic DNS cache'),
			_('Disable optimistic DNS caching in this query.'));
		so.depends('action', 'route');
		so.depends('action', 'evaluate');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'rewrite_ttl', _('Rewrite TTL'),
			_('Rewrite TTL in DNS responses.'));
		so.datatype = 'uinteger';
		so.depends('action', 'route');
		so.depends('action', 'evaluate');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'dns_timeout', _('DNS query timeout'),
			_('Override the DNS query timeout for this rule, in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '10';
		so.depends('action', 'route');
		so.depends('action', 'evaluate');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.depends('action', 'route');
		so.depends('action', 'evaluate');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
		so.value('default', _('Reply with REFUSED'));
		so.value('drop', _('Drop requests'));
		so.default = 'default';
		so.depends('action', 'reject');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop requests'),
			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
				_('Method'), _('Drop requests')));
		so.depends('reject_method', 'default');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'predefined_rcode', _('RCode'),
			_('The response code.'));
		so.value('NOERROR');
		so.value('FORMERR');
		so.value('SERVFAIL');
		so.value('NXDOMAIN');
		so.value('NOTIMP');
		so.value('REFUSED');
		so.default = 'NOERROR';
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_answer', _('Answer'),
			_('List of text DNS record to respond as answers.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_ns', _('NS'),
			_('List of text DNS record to respond as name servers.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_extra', _('Extra records'),
			_('List of text DNS record to respond as extra records.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domains'),
			_('Match full domain.'));
		so.datatype = 'hostname';
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
			_('Match domain suffix.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
			_('Match domain using keyword.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
			_('Match domain using regular expression.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
			_('Match source IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
			_('Match IP CIDR with query response. Current rule will be skipped if not match.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'),
			_('Match private IP with query response.'));
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
			_('Match source port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
			_('Match source port range. Format as START:/:END/START:END.'));
		so.validate = sb.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
			_('Match port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
			_('Match port range. Format as START:/:END/START:END.'));
		so.validate = sb.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
			_('Match process name.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
			_('Match process path.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
			_('Match process path using regular expression.'));
		so.modalonly = true;
		/* DNS rules end */
		/* Custom routing settings end */

		/* Rule set settings start */
		s.tab('ruleset', _('Rule Set'));
		o = s.taboption('ruleset', form.SectionValue, '_ruleset', form.GridSection, 'ruleset');
		o.depends('routing_mode', 'custom');
		o.depends('routing_mode', 'bypass_mainland_china');
		o.retain = true;

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(sb.loadModalTitle, this, _('Rule Set'), _('Add a rule set'), data[0]);
		ss.sectiontitle = L.bind(sb.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(sb.renderSectionAdd, this, ss);

		so = ss.option(form.Value, 'label', _('Label'));
		so.load = L.bind(sb.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(sb.validateUniqueValue, this, data[0], 'ruleset', 'label');
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'type', _('Type'));
		so.value('local', _('Local'));
		so.value('remote', _('Remote'));
		so.default = 'remote';
		so.rmempty = false;

		so = ss.option(form.ListValue, 'format', _('Format'));
		so.value('binary', _('Binary file'));
		so.value('source', _('Source file'));
		so.default = 'binary';
		so.rmempty = false;

		so = ss.option(form.Value, 'path', _('Path'));
		so.datatype = 'file';
		so.placeholder = '/etc/sbproxy/ruleset/example.json';
		so.rmempty = false;
		so.depends('type', 'local');
		so.modalonly = true;

		so = ss.option(form.Value, 'url', _('Rule set URL'));
		so.validate = function(section_id, value) {
			if (section_id) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value);
					if (!url.hostname)
						return _('Expecting: %s').format(_('valid URL'));
				}
				catch(e) {
					return _('Expecting: %s').format(_('valid URL'));
				}
			}

			return true;
		}
		so.rmempty = false;
		so.depends('type', 'remote');
		so.modalonly = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('Tag of the outbound to download rule set.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Default'));
			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'direct-out';
		so.depends({ type: 'remote', 'sbproxy.config.routing_mode': 'custom' });
		so.retain = true;

		so = ss.option(form.ListValue, 'diversion_download_outbound', _('Rule-set download in mainland mode'),
			_('Separate from the custom-routing download outbound. Only rule sets referenced by enabled diversion groups are loaded in mainland mode.'));
		so.value('direct-out', _('Direct'));
		so.value('main-out', _('Main node / URLTest'));
		so.default = 'direct-out';
		so.depends({ type: 'remote', 'sbproxy.config.routing_mode': 'bypass_mainland_china' });
		so.retain = true;
		so.modalonly = true;

		so = ss.option(form.Value, 'update_interval', _('Update interval'),
			_('Update interval of rule set.'));
		so.placeholder = '1d';
		so.depends('type', 'remote');
		/* Rule set settings end */

		/* ACL settings start */
		s.tab('control', _('Access Control'));

		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'sbproxy');
		ss = o.subsection;

		/* Interface control start */
		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;
		/* Interface control end */

		ss.tab('ingress', _('Ingress interface policy'));
		so = ss.taboption('ingress', form.Flag, 'ingress_enabled', _('Enable ingress interface policy'),
			_('Optional: bypass SBProxy for selected incoming WiFi networks or devices. Unselected sources keep the existing listen-interface and routing behavior. No subnet or DHCP changes are required.'));
		so.default = so.disabled;
		so.rmempty = false;
		so = ss.taboption('ingress', sb.CBIEmptySafeMultiValue, 'ingress_bypass_wifi', _('WiFi networks to bypass'),
			_('WiFi selections follow their configuration sections when device names change. Networks with identical SSIDs are distinguished by radio and section.'));
		uci.sections('wireless', 'wifi-iface', (wifi) => {
			if (wifi.mode === 'ap' || !wifi.mode)
				so.value(wifi['.name'], '%s — %s (%s)'.format(wifi.ssid || wifi['.name'], wifi.device || '-', wifi['.name']));
		});
		for (const selected of L.toArray(uci.get('sbproxy', 'control', 'ingress_bypass_wifi')))
			if (!uci.get('wireless', selected))
				so.value(selected, selected);
		so.depends('ingress_enabled', '1');
		so = ss.taboption('ingress', widgets.DeviceSelect, 'ingress_bypass_devices', _('Devices to bypass'),
			_('Select a bridge to bypass all its members, or select individual wired ports. Prefer the WiFi selector for wireless networks. This overrides proxy rules for the selected incoming traffic, but does not disable upstream-router proxies.'));
		so.multiple = true;
		so.noaliases = true;
		so.filter = function(section_id, value) {
			return value !== 'lo' && value !== (uci.get('sbproxy', 'infra', 'tun_name') || 'singtun0');
		};
		so.depends('ingress_enabled', '1');
		so = ss.taboption('ingress', form.DummyValue, '_ingress_note', _('Policy notes'));
		so.depends('ingress_enabled', '1');
		so.rawhtml = false;
		so.cfgvalue = () => _('Selected sources use direct upstream DNS for ordinary port-53 queries; local names and reverse lookups remain with dnsmasq. Existing or hardware-accelerated connections may keep their previous path: reconnect clients after changing policy. Disabling this option removes only SBProxy ingress rules.');

		so = ss.taboption('ingress', form.DummyValue, '_ingress_status', _('Ingress policy status'));
		so.depends('ingress_enabled', '1');
		so.renderWidget = function() {
			return E('div', { id: 'sbproxy-ingress-runtime' }, ingressStatusContent(data[4] || {}));
		};
		poll.add(function() {
			const element = document.getElementById('sbproxy-ingress-runtime');
			if (!element || element.offsetParent === null || document.hidden) return Promise.resolve();
			return L.resolveDefault(callIngressStatus(), { error: _('Unable to read ingress policy status') })
				.then((status) => { if (element.isConnected) dom.content(element, ingressStatusContent(status)); });
		}, 10);

		/* LAN IP policy start */
		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Direct MAC addresses'),
			_('MAC addresses in this option are forced to use global direct routing.'), hosts);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Direct IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global direct routing.'), 'ipv4', hosts, true);

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Proxy MAC addresses'),
			_('MAC addresses in this option are forced to use global proxy routing.'), hosts);
		so.depends('sbproxy.config.routing_mode', 'bypass_mainland_china');
		so.depends('sbproxy.config.routing_mode', 'custom');
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Proxy IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global proxy routing.'), 'ipv4', hosts, true);
		so.depends('sbproxy.config.routing_mode', 'bypass_mainland_china');
		so.depends('sbproxy.config.routing_mode', 'custom');
		so.retain = true;
		/* LAN IP policy end */

		/* WAN IP policy start */
		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global proxy routing.'));
		so.datatype = 'or(ip4addr, cidr4)';
		so.depends('sbproxy.config.routing_mode', 'bypass_mainland_china');
		so.depends('sbproxy.config.routing_mode', 'custom');
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 addresses'),
			_('IPv6 addresses in this option are forced to use global proxy routing.'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends({
			'sbproxy.config.routing_mode': 'bypass_mainland_china',
			'sbproxy.config.ipv6_support': '1'
		});
		so.depends({
			'sbproxy.config.routing_mode': 'custom',
			'sbproxy.config.ipv6_support': '1'
		});
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Direct IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global direct routing.'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Direct IPv6 addresses'),
			_('IPv6 addresses in this option are forced to use global direct routing.'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('sbproxy.config.ipv6_support', '1');
		so.retain = true;
		/* WAN IP policy end */

		/* Proxy domain list start */
		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends('sbproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return writeDomainList('proxy_list', 'proxy_domain_list_checksum', value);
		}
		so.remove = function(/* ... */) {
			return writeDomainList('proxy_list', 'proxy_domain_list_checksum', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Proxy domain list end */

		/* Direct domain list start */
		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends('sbproxy.config.routing_mode', 'bypass_mainland_china');
		so.depends('sbproxy.config.routing_mode', 'global');
		so.retain = true;
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return writeDomainList('direct_list', 'direct_domain_list_checksum', value);
		}
		so.remove = function(/* ... */) {
			return writeDomainList('direct_list', 'direct_domain_list_checksum', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Direct domain list end */
		/* ACL settings end */

		s.tab('advanced', _('Advanced Settings'));

		o = s.taboption('advanced', form.Flag, 'memory_guard_enabled', _('Memory pressure guard'),
			_('Monitor sing-box memory pressure, release unused memory and rebuild network state before the process exhausts router memory. Applied independently to the client and server processes.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'memory_guard_limit', _('Memory limit per process'),
			_('Soft memory limit in MiB for each sing-box process. The guard acts before this limit is reached.'));
		o.default = '256';
		o.datatype = 'range(32,4096)';
		o.depends('memory_guard_enabled', '1');
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'memory_guard_safety_margin', _('Memory safety margin'),
			_('The guard starts reclaiming memory when usage is this many MiB below the configured limit.'));
		o.default = '32';
		o.datatype = 'range(4,2048)';
		o.depends('memory_guard_enabled', '1');
		o.rmempty = false;
		o.validate = function(section_id, value) {
			const limit = Number(this.section.formvalue(section_id, 'memory_guard_limit'));
			return !section_id || Number(value) < limit ? true :
				_('The safety margin must be smaller than the memory limit.');
		};

		o = s.taboption('advanced', form.Flag, 'dns_disable_cache', _('Disable DNS cache'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'dns_disable_cache_expire', _('Disable DNS cache expiration'));
		o.default = o.disabled;
		o.depends('dns_disable_cache', '0');
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'dns_optimistic', _('Optimistic DNS cache'),
			_('Serve expired DNS entries while refreshing them in the background.'));
		o.default = o.disabled;
		o.depends({ dns_disable_cache: '0', dns_disable_cache_expire: '0' });
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'dns_optimistic_timeout', _('Optimistic cache timeout'),
			_('Maximum time in seconds to serve an expired DNS entry while it is refreshed.'));
		o.default = '259200';
		o.datatype = 'uinteger';
		o.depends({ dns_disable_cache: '0', dns_disable_cache_expire: '0', dns_optimistic: '1' });
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'dns_cache_capacity', _('DNS cache capacity'),
			_('Maximum number of cached DNS entries. The sing-box minimum is 1024.'));
		o.default = '1024';
		o.datatype = 'range(1024,1048576)';
		o.depends('dns_disable_cache', '0');
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'dns_timeout', _('DNS query timeout'),
			_('The default timeout for DNS queries, in seconds.'));
		o.default = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

		return m.render();
	}
});
