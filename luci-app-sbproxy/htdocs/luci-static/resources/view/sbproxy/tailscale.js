/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

'require sbproxy as sb';
'require tools.widgets as widgets';

const callTailscaleStatus = rpc.declare({
	object: 'luci.sbproxy',
	method: 'tailscale_status',
	expect: { '': {} }
});

const callTailscaleLogout = rpc.declare({
	object: 'luci.sbproxy',
	method: 'tailscale_logout',
	expect: { '': {} }
});

const callTailscalePeerDetails = rpc.declare({
	object: 'luci.sbproxy',
	method: 'tailscale_peer_details',
	params: [ 'target' ],
	expect: { '': {} }
});

const callTailscalePing = rpc.declare({
	object: 'luci.sbproxy',
	method: 'tailscale_ping',
	params: [ 'target' ],
	expect: { '': {} }
});

/* Theme headers can stick below the page toolbar even inside a horizontal
 * scroll container, covering peer rows. Keep status headers in normal flow
 * and contain theme table margins within each scrollable table. */
const tailscaleStatusStyle = `
#tailscale_status .table .tr > .th {
	position: static;
}
#tailscale_status .sbproxy-tailscale-table {
	min-width: 0;
	overflow-x: auto;
}
#tailscale_status .sbproxy-tailscale-table > .table {
	width: 100% !important;
	margin: 0;
}
`;

function ipv4Subnet(address) {
	const parts = (address || '').split('/');
	const cidr = Number(parts[1]);
	const octets = parts[0]?.split('.').map(Number);
	if (parts.length !== 2 || !Number.isInteger(cidr) || cidr < 1 || cidr >= 32 ||
	    octets?.length !== 4 || octets.some(octet => !Number.isInteger(octet) || octet < 0 || octet > 255))
		return null;

	const mask = (0xffffffff << (32 - cidr)) >>> 0;
	const numeric = octets.reduce((value, octet) => ((value << 8) | octet) >>> 0, 0);
	const subnet = (numeric & mask) >>> 0;
	return [ 24, 16, 8, 0 ].map(shift => (subnet >>> shift) & 255).join('.') + '/' + cidr;
}

async function getLocalAdvertiseSubnets() {
	const ignored = [ 'loopback', 'tailscale', 'sbproxy_ts' ];
	const networks = await network.getNetworks();
	const candidates = [], seen = new Set();

	for (const iface of networks) {
		const name = iface.getName();
		if (ignored.includes(name) || /^tailscale\d*$/.test(name) || /^singtun\d*$/.test(name))
			continue;
		for (const address of (iface.getIPAddrs() || [])) {
			const subnet = ipv4Subnet(address);
			if (!subnet || seen.has(subnet) || subnet.startsWith('127.') || subnet.startsWith('169.254.'))
				continue;
			seen.add(subnet);
			candidates.push({ value: subnet, network: name });
		}
	}
	return candidates;
}

function tailscaleStatusRow(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '32%' }, label),
		E('td', { 'class': 'td left' }, value === undefined || value === null || value === '' ? '-' : value)
	]);
}

function tailscaleStatusSection(title, content, description) {
	const children = [ E('h3', {}, title) ];
	if (description)
		children.push(E('p', { 'class': 'cbi-section-descr' }, description));
	children.push(content);
	return E('div', { 'class': 'cbi-section' }, children);
}

function formatTailscaleBytes(value) {
	const bytes = Number(value);
	return Number.isFinite(bytes) && bytes >= 0 ? '%1024mB'.format(bytes) : '-';
}

function renderTailscaleRouteDiscovery(status) {
	if (status?.peer_routes_available === true)
		return E('span', { 'style': 'color:green' }, _('Available'));
	if (status?.peer_routes_available === false)
		return E('span', {
			'style': 'color:orange',
			'title': status.peer_routes_error || ''
		}, _('Unavailable; configured routes are kept'));
	return '-';
}

function renderTailscaleAccountControl(status) {
	const backendState = status?.backend_state;
	if (backendState === 'Running') {
		const accountName = status?.self?.user || status?.network_name || _('Connected');
		const accountLink = E('a', {
			'href': 'https://login.tailscale.com/admin/machines',
			'target': '_blank',
			'rel': 'noreferrer noopener'
		}, accountName);
		const button = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-negative'
		}, _('Log out'));
		button.onclick = async function() {
			if (!confirm(_('Are you sure you want to log out of Tailscale on this device?')))
				return;
			button.disabled = true;
			const result = await callTailscaleLogout();
			ui.addNotification(null, E('p', {}, [
				result.code === 0 ? _('Tailscale logged out.') : (result.output || _('Logout failed.'))
			]), result.code === 0 ? 'info' : 'error');
			button.disabled = false;
			if (result.code === 0)
				window.setTimeout(() => window.location.reload(), 500);
		};
		return E('div', {}, [
			E('span', { 'style': 'color:green' }, [ _('Connected') + ': ', accountLink ]),
			E('br'),
			button
		]);
	}
	if (backendState === 'NeedsLogin') {
		return status?.auth_url && /^https?:\/\//i.test(status.auth_url)
			? E('a', {
				'href': status.auth_url,
				'target': '_blank',
				'rel': 'noreferrer noopener'
			}, _('Open login page'))
			: E('span', { 'style': 'color:orange' }, _('Waiting for login URL'));
	}
	if (backendState === 'NeedsMachineAuth')
		return E('span', { 'style': 'color:orange' }, _('Waiting for machine approval'));
	return _('Not logged in');
}

function formatTailscaleBackendState(status) {
	const backendState = status?.backend_state;
	if (!backendState)
		return status?.enabled ? _('Not running') : _('Disabled');
	switch (backendState) {
	case 'Running':
		return _('Connected');
	case 'NeedsLogin':
	case 'NoState':
		return _('Not logged in');
	case 'NeedsMachineAuth':
		return _('Waiting for machine approval');
	case 'Disabled':
		return _('Disabled');
	default:
		return backendState;
	}
}

function resolveTailscaleStatus(timeout = 800, fallback = {}) {
	let timer;
	return Promise.race([
		callTailscaleStatus(),
		new Promise(resolve => {
			timer = window.setTimeout(() => resolve(fallback), timeout);
		})
	]).finally(() => window.clearTimeout(timer));
}

function tailscaleStateLabel(state, detail) {
	const colours = { healthy: 'green', warning: 'orange', error: 'red' };
	const labels = { healthy: _('Healthy'), warning: _('Warning'), error: _('Error') };
	return E('span', { 'style': `color:${colours[state]}`, 'title': detail || '' }, labels[state]);
}

function renderTailscaleNodeOverview(status, configuredAdvertiseRoutes) {
	const selectedExitNode = (status?.exit_nodes || []).find(node => node.selected);
	const self = status?.self || {};
	return E('table', { 'class': 'table' }, [
		tailscaleStatusRow(_('Backend State'), formatTailscaleBackendState(status)),
		tailscaleStatusRow(_('Account'), self.user || status?.network_name),
		tailscaleStatusRow(_('Tailnet'), status?.network_name),
		tailscaleStatusRow(_('Hostname'), self.host_name),
		tailscaleStatusRow(_('DNS Name'), self.dns_name),
		tailscaleStatusRow(_('Tailscale Addresses'), (self.ips || []).join(', ')),
		tailscaleStatusRow(_('Operating System'), self.os),
		tailscaleStatusRow(_('Stable ID'), self.stable_id),
		tailscaleStatusRow(_('Key Expiry'), self.key_expiry || _('No expiry reported')),
		tailscaleStatusRow(_('Advertised Routes'), configuredAdvertiseRoutes.length ? configuredAdvertiseRoutes.join(', ') : _('None')),
		tailscaleStatusRow(_('Exit Node Offered'), self.exit_node === 'offered' ? _('Yes') : (self.exit_node || _('No'))),
		tailscaleStatusRow(_('Exit Node in Use'), selectedExitNode ?
			`${selectedExitNode.name} (${selectedExitNode.address})` : _('None'))
	]);
}

function renderTailscaleHealth(status) {
	const interfaceStatus = status?.interface || {};
	const routing = status?.system_routing || {};
	const addressReady = (interfaceStatus.ipv4 || []).length > 0 || (interfaceStatus.ipv6 || []).length > 0;
	const checks = [
		{
			label: _('Embedded backend'),
			state: status?.running ? 'healthy' : 'error',
			detail: formatTailscaleBackendState(status)
		},
		{
			label: _('Tailnet account'),
			state: status?.network_name ? 'healthy' : 'warning',
			detail: status?.network_name || _('No logged-in account detected')
		},
		{
			label: _('System interface'),
			state: interfaceStatus.present && interfaceStatus.up && addressReady ? 'healthy' : 'error',
			detail: interfaceStatus.present ?
				(interfaceStatus.up ? (addressReady ? _('Interface and addresses are ready') : _('Interface has no Tailscale address')) : _('Present but down')) :
				_('Interface is missing')
		},
		{
			label: _('Peer status API'),
			state: status?.peers_available === true ? 'healthy' : 'warning',
			detail: status?.peers_available === true ? _('%d nodes detected').format((status.peers || []).length) :
				(status?.peers_error || _('Peer status is unavailable'))
		},
		{
			label: _('Peer route API'),
			state: status?.peer_routes_available === true ? 'healthy' : 'warning',
			detail: status?.peer_routes_available === true ? _('%d routes advertised by peers').format((status.peer_routes || []).length) :
				(status?.peer_routes_error || _('Peer route status is unavailable'))
		},
		{
			label: _('System policy routing'),
			state: routing.available && (routing.rules || []).length > 0 ? 'healthy' : 'warning',
			detail: routing.available ? _('%d table 52 rules installed').format((routing.rules || []).length) : _('Unable to inspect system routing')
		}
	];
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Check')),
			E('th', { 'class': 'th' }, _('State')),
			E('th', { 'class': 'th' }, _('Details'))
		]),
		...checks.map(check => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, check.label),
			E('td', { 'class': 'td' }, tailscaleStateLabel(check.state, check.detail)),
			E('td', { 'class': 'td' }, check.detail)
		]))
	]);
}

function renderTailscaleInterface(status) {
	const interfaceStatus = status?.interface || {};
	const interfaceState = interfaceStatus.present ?
		(interfaceStatus.up ? _('Available') : _('Present but down')) : _('Unavailable');
	return E('table', { 'class': 'table' }, [
		tailscaleStatusRow(_('System interface'), interfaceStatus.name),
		tailscaleStatusRow(_('Interface Management'), _('Managed by sing-box')),
		tailscaleStatusRow(_('Interface State'), interfaceState),
		tailscaleStatusRow(_('Tailscale IPv4'), (interfaceStatus.ipv4 || []).join(', ')),
		tailscaleStatusRow(_('Tailscale IPv6'), (interfaceStatus.ipv6 || []).join(', ')),
		tailscaleStatusRow(_('Interface MTU'), interfaceStatus.mtu),
		tailscaleStatusRow(_('Received / Sent'), `${formatTailscaleBytes(interfaceStatus.rx_bytes)} / ${formatTailscaleBytes(interfaceStatus.tx_bytes)}`)
	]);
}

function renderTailscaleRoutes(status, configuredPeerRoutes, acceptRoutes) {
	const systemRouting = status?.system_routing || {};
	const systemRoutes = systemRouting.routes || [];
	const interfaceName = status?.interface?.name;
	const peerRoutes = status?.peer_routes || [];
	const routeRows = [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Route')),
			E('th', { 'class': 'th' }, _('Peer')),
			E('th', { 'class': 'th' }, _('Peer State')),
			E('th', { 'class': 'th' }, _('System State'))
		])
	];
	for (const route of peerRoutes) {
		const configured = acceptRoutes && configuredPeerRoutes.includes(route.route);
		const installed = systemRoutes.some(entry => entry.destination === route.route && entry.device === interfaceName);
		routeRows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, route.route),
			E('td', { 'class': 'td' }, route.name || route.address),
			E('td', { 'class': 'td' }, route.online ? _('Online') : _('Offline')),
			E('td', { 'class': 'td' }, installed ? E('span', { 'style': 'color:green' }, _('Installed')) :
				(configured ? E('span', { 'style': 'color:orange' }, _('Configured but not installed')) : _('Not selected')))
		]));
	}
	if (!peerRoutes.length)
		routeRows.push(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 4 }, _('No peer routes advertised.'))));

	const systemRows = [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Family')),
			E('th', { 'class': 'th' }, _('Destination')),
			E('th', { 'class': 'th' }, _('Interface')),
			E('th', { 'class': 'th' }, _('Gateway'))
		])
	];
	for (const route of systemRoutes)
		systemRows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, route.family),
			E('td', { 'class': 'td' }, route.destination),
			E('td', { 'class': 'td' }, route.device || '-'),
			E('td', { 'class': 'td' }, route.gateway || '-')
		]));
	if (!systemRoutes.length)
		systemRows.push(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 4 }, _('No routes installed in table 52.'))));

	return E('div', {}, [
		E('table', { 'class': 'table' }, [
			tailscaleStatusRow(_('Peer Route Discovery'), renderTailscaleRouteDiscovery(status)),
			tailscaleStatusRow(_('Accept Routes'), acceptRoutes ? _('Enabled') : _('Disabled')),
			tailscaleStatusRow(_('Policy Rules'), _('%d table 52 rules').format((systemRouting.rules || []).length))
		]),
		E('h4', {}, _('Routes Advertised by Peers')),
		E('div', { 'class': 'sbproxy-tailscale-table' }, E('table', { 'class': 'table' }, routeRows)),
		E('h4', {}, _('Installed System Routes')),
		E('div', { 'class': 'sbproxy-tailscale-table' }, E('table', { 'class': 'table' }, systemRows))
	]);
}

function renderPeerDetails(peer) {
	return E('table', { 'class': 'table' }, [
		tailscaleStatusRow(_('Hostname'), peer?.host_name),
		tailscaleStatusRow(_('DNS Name'), peer?.dns_name),
		tailscaleStatusRow(_('User'), peer?.user),
		tailscaleStatusRow(_('Operating System'), peer?.os),
		tailscaleStatusRow(_('Tailscale Addresses'), (peer?.ips || []).join(', ')),
		tailscaleStatusRow(_('Stable ID'), peer?.stable_id),
		tailscaleStatusRow(_('State'), peer?.online ? (peer.active ? _('Active') : _('Online')) : _('Offline')),
		tailscaleStatusRow(_('Key Expired'), peer?.expired ? _('Yes') : _('No')),
		tailscaleStatusRow(_('Key Expiry'), peer?.key_expiry || _('No expiry reported')),
		tailscaleStatusRow(_('Last Seen'), peer?.last_seen),
		tailscaleStatusRow(_('Exit Node'), peer?.exit_node === 'offered' ? _('Available') : peer?.exit_node),
		tailscaleStatusRow(_('Received / Sent'), `${formatTailscaleBytes(peer?.rx_bytes)} / ${formatTailscaleBytes(peer?.tx_bytes)}`)
	]);
}

async function showTailscalePeerDetails(peer, button) {
	button.disabled = true;
	try {
		const result = await callTailscalePeerDetails(peer.address);
		if (result.code !== 0 || !result.peer) {
			ui.addNotification(null, E('p', {}, result.output || _('Unable to read peer details.')), 'error');
			return;
		}
		ui.showModal(_('Peer Details'), [
			renderPeerDetails(result.peer),
			E('div', { 'class': 'right' }, E('button', {
				'type': 'button',
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, _('Close')))
		]);
	} finally {
		button.disabled = false;
	}
}

async function probeTailscalePeerPath(peer, button) {
	button.disabled = true;
	try {
		const result = await callTailscalePing(peer.address);
		ui.showModal(_('Peer Path'), [
			E('pre', { 'style': 'white-space:pre-wrap' },
				(result.output || (result.code === 0 ? _('Peer is reachable.') : _('Peer test failed.'))).trim()),
			E('div', { 'class': 'right' }, E('button', {
				'type': 'button',
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, _('Close')))
		]);
	} finally {
		button.disabled = false;
	}
}

function renderTailscalePeers(status) {
	const peers = (status?.peers || []).filter(peer => !peer.self).sort((a, b) => {
		if (a.online !== b.online)
			return a.online ? -1 : 1;
		return (a.dns_name || '').localeCompare(b.dns_name || '');
	});
	const rows = [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Peer')),
			E('th', { 'class': 'th' }, _('Tailscale IP')),
			E('th', { 'class': 'th' }, _('State')),
			E('th', { 'class': 'th' }, _('Actions'))
		])
	];
	for (const peer of peers) {
		const detailsButton = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-neutral'
		}, _('Details'));
		const pathButton = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action'
		}, _('Test Path'));
		detailsButton.onclick = () => showTailscalePeerDetails(peer, detailsButton);
		pathButton.onclick = () => probeTailscalePeerPath(peer, pathButton);
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, peer.dns_name || '-'),
			E('td', { 'class': 'td' }, peer.address || '-'),
			E('td', { 'class': 'td' }, peer.online ? E('span', { 'style': 'color:green' }, _('Online')) : _('Offline')),
			E('td', { 'class': 'td' }, [ detailsButton, ' ', pathButton ])
		]));
	}
	if (!peers.length)
		rows.push(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 4 }, _('No peers found.'))));
	return E('div', { 'class': 'sbproxy-tailscale-table' }, E('table', { 'class': 'table' }, rows));
}

function renderTailscaleStatus(status, configuredPeerRoutes, configuredAdvertiseRoutes, acceptRoutes) {
	const content = [
		tailscaleStatusSection(_('Node Overview'), renderTailscaleNodeOverview(status, configuredAdvertiseRoutes)),
		tailscaleStatusSection(_('Health Status'), renderTailscaleHealth(status),
			_('Derived locally from the embedded backend, interface, peer API, and system routes. This is not the official Tailscale Health or netcheck result.')),
		tailscaleStatusSection(_('Peers'), renderTailscalePeers(status)),
		tailscaleStatusSection(_('Interface'), renderTailscaleInterface(status)),
		tailscaleStatusSection(_('Route Status'), renderTailscaleRoutes(status, configuredPeerRoutes, acceptRoutes))
	];
	if (status?.enabled && status?.code !== 0)
		content.unshift(E('div', { 'class': 'alert-message warning' },
			(status.output || _('Waiting for the embedded backend...')).trim()));
	return E('div', {}, content);
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('sbproxy'),
			sb.getBuiltinFeatures(),
			L.resolveDefault(uci.load('tailscale'), null),
			L.resolveDefault(resolveTailscaleStatus(), {}),
			L.resolveDefault(getLocalAdvertiseSubnets(), [])
		]);
	},

	render(data) {
		let m, s, o, subnetRouteOption, advertiseRouteOption, exitNodeOption;
		const features = data[1];
		const tailscaleStatus = data[3] || {};
		const standaloneTailscaleEnabled = tailscaleStatus.standalone_installed === true &&
			uci.get('tailscale', 'settings', 'enabled') === '1';
		const configuredExitNode = uci.get(data[0], 'tailscale', 'exit_node') || '';
		const configuredPeerRoutes = L.toArray(uci.get(data[0], 'tailscale', 'subnet_routes'));
		const configuredAdvertiseRoutes = L.toArray(uci.get(data[0], 'tailscale', 'advertise_routes'));
		const acceptRoutes = uci.get(data[0], 'tailscale', 'accept_routes') === '1';
		const localAdvertiseSubnets = data[4] || [];

		m = new form.Map('sbproxy', _('Virtual Networking'),
			_('Runs Tailscale inside the SBProxy sing-box process. It can run without a proxy node; the independent Tailscale service must be disabled first.'));

		s = m.section(form.NamedSection, 'tailscale', 'sbproxy');
		s.hidetitle = true;
		s.tab('general', _('General Settings'));
		s.tab('routing', _('Routing Settings'));
		s.tab('dns', _('DNS Settings'));
		s.tab('security', _('Security'));
		s.tab('relay', _('Peer Relay'));
		s.tab('derp', _('DERP Server'));
		s.tab('authentication', _('Authentication'));
		s.tab('advanced', _('Extra Settings'),
			_('tailscale0 is the standard Tailscale kernel device; sbproxy_ts is the OpenWrt logical interface used by netifd and firewall integration.'));
		s.tab('status', _('Status'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable embedded Tailscale'),
			_('Runs Tailscale inside the SBProxy sing-box process. It can run without a proxy node; the independent Tailscale service must be disabled first.'));
		o.default = o.disabled;
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			if (value !== '1')
				return true;
			if (!features.with_tailscale)
				return _('The installed sing-box build does not include Tailscale support.');
			if (standaloneTailscaleEnabled)
				return _('Disable the independent Tailscale service before enabling the embedded backend.');
			return true;
		};

		o = s.taboption('general', form.DummyValue, '_account', _('Account'));
		o.depends('enabled', '1');
		o.renderWidget = function() {
			return E('div', { 'id': 'tailscale_account' }, renderTailscaleAccountControl(tailscaleStatus));
		};

		o = s.taboption('general', form.Value, 'hostname', _('Device name'));
		o.depends('enabled', '1');
		o.rmempty = true;

		o = s.taboption('routing', form.Flag, 'accept_routes', _('Accept routes'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		subnetRouteOption = s.taboption('routing', sb.CBIStaticList, 'subnet_routes', _('Static peer routes'),
			_('Select subnets advertised by peers after login. Custom CIDR values remain supported.'));
		/* Keep the dynamic-list combobox alive even when the initial status RPC
		 * times out before it can return peer routes. */
		subnetRouteOption.value('-', _('Loading'));
		const peerRouteValues = [];
		for (const route of (tailscaleStatus.peer_routes || [])) {
			if (!route.route || peerRouteValues.includes(route.route))
				continue;
			peerRouteValues.push(route.route);
			subnetRouteOption.value(route.route, route.route);
		}
		for (const route of configuredPeerRoutes) {
			if (!peerRouteValues.includes(route)) {
				peerRouteValues.push(route);
				subnetRouteOption.value(route, route);
			}
		}
		subnetRouteOption.datatype = 'or(cidr4,cidr6)';
		subnetRouteOption.validate = function(sectionId, value) {
			return !value.endsWith('/0') || _('The default route must be configured as an exit node.');
		};
		subnetRouteOption.depends({ enabled: '1', accept_routes: '1' });
		subnetRouteOption.rmempty = true;

		function getTailscaleWidget(option) {
			if (typeof option?.getUIElement !== 'function')
				return null;
			try {
				return option.getUIElement('tailscale');
			} catch (e) {
				return null;
			}
		}

		function addPeerRouteChoices(status) {
			const values = [], labels = {};
			for (const route of (status?.peer_routes || [])) {
				if (!route.route || peerRouteValues.includes(route.route))
					continue;
				values.push(route.route);
				labels[route.route] = route.route;
			}
			if (!values.length)
				return;

			const widget = getTailscaleWidget(subnetRouteOption);
			if (!widget || typeof widget.addChoices !== 'function')
				return;
			for (const value of values)
				peerRouteValues.push(value);
			widget.addChoices(values, labels);
		}

		advertiseRouteOption = s.taboption('routing', sb.CBIStaticList, 'advertise_routes', _('Advertise subnets'),
			_('Select local interface subnets to publish. Custom CIDR values remain supported.'));
		/* Keep this list upgradeable when an interface appears after the page was
		 * opened, while retaining the free-form CIDR fallback. */
		advertiseRouteOption.value('-', _('Loading'));
		const advertiseRouteValues = [];
		for (const route of localAdvertiseSubnets) {
			if (!route.value || advertiseRouteValues.includes(route.value))
				continue;
			advertiseRouteValues.push(route.value);
			advertiseRouteOption.value(route.value, route.value);
		}
		for (const route of configuredAdvertiseRoutes) {
			if (!advertiseRouteValues.includes(route)) {
				advertiseRouteValues.push(route);
				advertiseRouteOption.value(route, route);
			}
		}
		advertiseRouteOption.datatype = 'or(cidr4,cidr6)';
		advertiseRouteOption.depends('enabled', '1');
		advertiseRouteOption.rmempty = true;

		function addAdvertiseRouteChoices(routes) {
			const values = [], labels = {};
			for (const route of (routes || [])) {
				if (!route?.value || advertiseRouteValues.includes(route.value))
					continue;
				values.push(route.value);
				labels[route.value] = route.value;
			}
			if (!values.length)
				return;

			const widget = getTailscaleWidget(advertiseRouteOption);
			if (!widget || typeof widget.addChoices !== 'function')
				return;
			for (const value of values)
				advertiseRouteValues.push(value);
			widget.addChoices(values, labels);
		}

		function refreshAdvertiseRouteChoices() {
			return getLocalAdvertiseSubnets().then(addAdvertiseRouteChoices).catch(() => undefined);
		}

		o = s.taboption('routing', form.Flag, 'advertise_exit_node', _('Advertise exit node'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('routing', form.Flag, 'disable_snat_subnet_routes', _('Preserve subnet source addresses'),
			_('Disable SNAT for traffic forwarded from Tailscale. LAN devices must have a return route to the Tailnet address ranges.'));
		o.default = o.disabled;
		o.depends({ enabled: '1', advertise_exit_node: '0' });
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'exit_node', _('Use exit node'),
			_('Select an online Tailscale exit node.'));
		exitNodeOption = o;
		o.value('', _('None'));
		const exitNodeValues = [];
		for (const node of (tailscaleStatus.exit_nodes || [])) {
			if (!node.address || (!node.online && !node.selected) || exitNodeValues.includes(node.address))
				continue;
			exitNodeValues.push(node.address);
			o.value(node.address, (node.name || node.address) + ' (' + node.address + ')');
		}
		if (configuredExitNode && !exitNodeValues.includes(configuredExitNode)) {
			exitNodeValues.push(configuredExitNode);
			o.value(configuredExitNode, configuredExitNode + ' (' + _('offline or unavailable') + ')');
		}
		function addExitNodeChoices(status) {
			const widget = getTailscaleWidget(exitNodeOption);
			const select = widget?.node?.querySelector('select');
			if (!select)
				return;

			const options = {};
			select.querySelectorAll('option').forEach((option) => {
				options[option.value] = option;
			});
			for (const node of (status?.exit_nodes || [])) {
				if (!node.address || (!node.online && !node.selected))
					continue;
				const label = (node.name || node.address) + ' (' + node.address + ')';
				if (options[node.address])
					options[node.address].textContent = label;
				else {
					options[node.address] = E('option', { value: node.address }, label);
					select.appendChild(options[node.address]);
				}
				if (!exitNodeValues.includes(node.address))
					exitNodeValues.push(node.address);
			}
			if (configuredExitNode && !options[configuredExitNode]) {
				select.appendChild(E('option', {
					value: configuredExitNode
				}, configuredExitNode + ' (' + _('offline or unavailable') + ')'));
				exitNodeValues.push(configuredExitNode);
			}
		}
		o.depends({ enabled: '1', advertise_exit_node: '0' });
		o.default = '';
		o.rmempty = true;

		o = s.taboption('routing', form.Flag, 'exit_node_allow_lan_access', _('Allow LAN access with exit node'),
			_('Keep direct access to local LAN subnets while using an exit node.'));
		o.default = o.disabled;
		o.depends({ enabled: '1', advertise_exit_node: '0', exit_node: /.+/ });
		o.rmempty = false;

		o = s.taboption('routing', form.MultiValue, 'access', _('OpenWrt forwarding'));
		o.value('ts_ac_lan', _('Tailscale access LAN'));
		o.value('ts_ac_wan', _('Tailscale access WAN'));
		o.value('lan_ac_ts', _('LAN access Tailscale'));
		o.value('wan_ac_ts', _('WAN access Tailscale'));
		o.depends('enabled', '1');
		o.rmempty = true;

		o = s.taboption('dns', form.Flag, 'magic_dns', _('Forward MagicDNS'),
			_('Forward Tailnet DNS names through the sing-box Tailscale DNS transport without replacing OpenWrt system DNS.'));
		o.default = o.enabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('dns', form.Flag, 'accept_search_domain', _('Accept search domain'));
		o.default = o.enabled;
		o.depends({ enabled: '1', magic_dns: '1' });
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'ssh_server', _('Tailscale SSH'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'ssh_disable_pty', _('Disable SSH PTY'));
		o.default = o.disabled;
		o.depends({ enabled: '1', ssh_server: '1' });
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'ssh_disable_sftp', _('Disable SFTP'));
		o.default = o.disabled;
		o.depends({ enabled: '1', ssh_server: '1' });
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'ssh_disable_forwarding', _('Disable SSH forwarding'));
		o.default = o.disabled;
		o.depends({ enabled: '1', ssh_server: '1' });
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'taildrop_enabled', _('Taildrop'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('security', form.Value, 'taildrop_directory', _('Taildrop directory'));
		o.default = '/etc/sbproxy/tailscale/Taildrop';
		o.depends({ enabled: '1', taildrop_enabled: '1' });
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return value?.startsWith('/') ? true : _('Expecting: %s').format(_('absolute path'));
		};

		o = s.taboption('relay', form.Flag, 'relay_server_enabled', _('Enable peer relay'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('relay', form.Value, 'relay_server_port', _('Peer relay UDP port'));
		o.default = '0';
		o.datatype = 'range(0,65535)';
		o.depends({ enabled: '1', relay_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('relay', form.DynamicList, 'relay_server_static_endpoints', _('Static relay endpoints'));
		o.placeholder = '192.0.2.1:40000';
		o.depends({ enabled: '1', relay_server_enabled: '1' });
		o.rmempty = true;

		o = s.taboption('derp', form.Flag, 'derp_server_enabled', _('Enable DERP server'),
			_('Run a complete TLS-protected DERP and optional STUN server inside sing-box. Add this server to the Tailnet DERP map in Tailscale Access Controls before clients can use it.'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_listen', _('DERP listen address'));
		o.default = '::';
		o.datatype = 'ipaddr';
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_port', _('DERP HTTPS port'),
			_('Defaults to 8443 to avoid the LuCI HTTPS listener. Publish this exact port in the Tailnet DERP map, or forward an external port to it.'));
		o.default = '8443';
		o.datatype = 'port';
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Flag, 'derp_firewall', _('Open DERP firewall ports'),
			_('Accept the configured DERP TCP port and STUN UDP port from all firewall zones. Only enable this for an intentionally public server.'));
		o.default = o.enabled;
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_config_path', _('DERP identity path'),
			_('The DERP node private identity is generated automatically when this file does not exist.'));
		o.default = '/etc/sbproxy/tailscale/derp.json';
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return value?.startsWith('/') ? true : _('Expecting: %s').format(_('absolute path'));
		};

		o = s.taboption('derp', form.Flag, 'derp_verify_tailscale', _('Verify Tailnet clients'),
			_('Authorize DERP clients through the embedded Tailscale endpoint.'));
		o.default = o.enabled;
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.DynamicList, 'derp_verify_url', _('Additional client verification URLs'));
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			if (!value)
				return true;
			try {
				const url = new URL(value);
				return [ 'http:', 'https:' ].includes(url.protocol) && !!url.hostname ? true :
					_('Expecting: %s').format(_('valid URL'));
			} catch (e) {
				return _('Expecting: %s').format(_('valid URL'));
			}
		};

		o = s.taboption('derp', form.ListValue, 'derp_tls_mode', _('DERP certificate source'),
			_('Use certificate files or ACME for a public DERP server. The Tailscale certificate option is intended for Tailnet-only deployments and requires HTTPS certificates enabled in Tailnet DNS settings.'));
		o.value('manual', _('Certificate files'));
		if (features.with_acme)
			o.value('acme', _('ACME'));
		o.value('tailscale', _('Tailscale certificate'));
		o.default = 'manual';
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_cert_path', _('DERP certificate path'));
		o.default = '/etc/sbproxy/certs/server_publickey.pem';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'manual' });
		o.validate = sb.validateCertificatePath;
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_key_path', _('DERP private key path'));
		o.default = '/etc/sbproxy/certs/server_privatekey.pem';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'manual' });
		o.validate = sb.validateCertificatePath;
		o.rmempty = false;

	if (features.with_acme) {
		o = s.taboption('derp', form.DynamicList, 'derp_acme_domain', _('DERP domains'));
		o.datatype = 'hostname';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'acme' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_acme_email', _('DERP ACME email'));
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'acme' });
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return !sectionId || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value || '') ? true :
				_('Expecting: %s').format(_('valid email address'));
		};

		o = s.taboption('derp', form.ListValue, 'derp_acme_provider', _('DERP ACME provider'));
		o.value('letsencrypt', _('Let\'s Encrypt'));
		o.value('zerossl', _('ZeroSSL'));
		o.default = 'letsencrypt';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'acme' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_acme_http_port', _('DERP ACME alternative HTTP port'));
		o.datatype = 'port';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'acme' });

		o = s.taboption('derp', form.Value, 'derp_acme_tls_port', _('DERP ACME alternative TLS port'));
		o.datatype = 'port';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_tls_mode: 'acme' });
	}

		o = s.taboption('derp', form.ListValue, 'derp_home', _('DERP home page'));
		o.value('', _('Default information page'));
		o.value('blank', _('Blank page'));
		o.default = '';
		o.editable = true;
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.validate = function(sectionId, value) {
			if (!value || value === 'blank')
				return true;
			try {
				const url = new URL(value);
				return [ 'http:', 'https:' ].includes(url.protocol) && !!url.hostname ? true :
					_('Expecting: %s').format(_('blank or valid URL'));
			} catch (e) {
				return _('Expecting: %s').format(_('blank or valid URL'));
			}
		};

		o = s.taboption('derp', form.DynamicList, 'derp_mesh_server', _('DERP mesh peers'),
			_('Other DERP servers in host:port format. All mesh peers share the configured PSK.'));
		o.placeholder = 'derp2.example.com:443';
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			const match = String(value || '').match(/^(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):(\d{1,5})$/);
			if (value && (!match || Number(match[1]) < 1 || Number(match[1]) > 65535))
				return _('Expecting: %s').format(_('host:port'));
			if (value && !this.section.formvalue(sectionId, 'derp_mesh_psk') &&
			    !this.section.formvalue(sectionId, 'derp_mesh_psk_file'))
				return _('A mesh PSK or PSK file is required when DERP mesh peers are configured.');
			return true;
		};

		o = s.taboption('derp', form.Value, 'derp_mesh_psk', _('DERP mesh PSK'));
		o.password = true;
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_mesh_psk_file: '' });
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			return !value || /^[0-9a-f]{64}$/.test(value) ? true :
				_('Expecting: %s').format(_('64 lowercase hexadecimal characters'));
		};

		o = s.taboption('derp', form.Value, 'derp_mesh_psk_file', _('DERP mesh PSK file'));
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_mesh_psk: '' });
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			return !value || value.startsWith('/') ? true : _('Expecting: %s').format(_('absolute path'));
		};

		o = s.taboption('derp', form.Flag, 'derp_stun_enabled', _('Enable DERP STUN'));
		o.default = o.enabled;
		o.depends({ enabled: '1', derp_server_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_stun_listen', _('DERP STUN listen address'));
		o.default = '::';
		o.datatype = 'ipaddr';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_stun_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('derp', form.Value, 'derp_stun_port', _('DERP STUN port'));
		o.default = '3478';
		o.datatype = 'port';
		o.depends({ enabled: '1', derp_server_enabled: '1', derp_stun_enabled: '1' });
		o.rmempty = false;

		o = s.taboption('authentication', form.Value, 'control_url', _('Control server'),
			_('Leave blank for the official Tailscale control plane, or enter a Headscale URL.'));
		o.placeholder = 'https://controlplane.tailscale.com';
		o.depends('enabled', '1');
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			if (!value)
				return true;
			try {
				const url = new URL(value);
				return [ 'http:', 'https:' ].includes(url.protocol) && !!url.hostname ? true :
					_('Expecting: %s').format(_('valid URL'));
			} catch (e) {
				return _('Expecting: %s').format(_('valid URL'));
			}
		};

		o = s.taboption('authentication', form.Value, 'auth_key', _('Auth key'));
		o.password = true;
		o.depends('enabled', '1');
		o.rmempty = true;

		o = s.taboption('authentication', form.Value, 'auth_key_file', _('Auth key file'));
		o.placeholder = '/etc/sbproxy/tailscale/auth.key';
		o.depends('enabled', '1');
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			return !value || value.startsWith('/') ? true : _('Expecting: %s').format(_('absolute path'));
		};

		o = s.taboption('authentication', form.Flag, 'ephemeral', _('Ephemeral node'));
		o.default = o.disabled;
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('authentication', form.DynamicList, 'advertise_tags', _('ACL tags'));
		o.placeholder = 'tag:router';
		o.depends('enabled', '1');
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, '_ping_target', _('Peer test target'),
			_('Enter a Tailscale IP address, machine name, or MagicDNS name.'));
		o.depends('enabled', '1');
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			return !value || /^[A-Za-z0-9_.:-]+$/.test(value) ? true :
				_('Expecting: %s').format(_('valid host name or IP address'));
		};

		o = s.taboption('advanced', form.Button, '_ping', _('Peer connectivity'));
		o.inputtitle = _('Ping peer');
		o.inputstyle = 'action';
		o.depends('enabled', '1');
		o.onclick = async function(sectionId) {
			const target = this.section.formvalue(sectionId, '_ping_target');
			if (!target) {
				ui.addNotification(null, E('p', {}, _('Enter a peer test target first.')), 'warning');
				return;
			}
			const result = await callTailscalePing(target);
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap' },
				(result.output || (result.code === 0 ? _('Peer is reachable.') : _('Peer test failed.'))).trim()),
				result.code === 0 ? 'info' : 'error');
		};

		o = s.taboption('advanced', form.Value, 'state_directory', _('State directory'));
		o.default = '/etc/sbproxy/tailscale';
		o.depends('enabled', '1');
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return value?.startsWith('/') ? true : _('Expecting: %s').format(_('absolute path'));
		};

		o = s.taboption('advanced', form.Value, 'system_interface_name', _('System interface'),
			_('Keep tailscale0 unless another Tailscale-compatible device name is explicitly required.'));
		o.default = 'tailscale0';
		o.depends('enabled', '1');
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return /^[A-Za-z0-9_.-]+$/.test(value || '') ? true : _('Expecting: %s').format(_('valid interface name'));
		};

		o = s.taboption('advanced', form.Value, 'system_interface_mtu', _('Interface MTU'));
		o.default = '1280';
		o.datatype = 'range(1280,9000)';
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'listen_port', _('UDP port'));
		o.default = '41641';
		o.datatype = 'port';
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('advanced', widgets.DeviceSelect, 'bind_interface', _('Underlay interface'));
		o.multiple = false;
		o.noaliases = true;
		o.depends('enabled', '1');

		o = s.taboption('advanced', form.Value, 'udp_timeout', _('UDP NAT expiration time'));
		o.default = '300';
		o.datatype = 'uinteger';
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.taboption('status', form.DummyValue, '_status');
		o.render = function() {
			return E('div', { 'id': 'tailscale_status' },
				renderTailscaleStatus(tailscaleStatus, configuredPeerRoutes, configuredAdvertiseRoutes, acceptRoutes));
		};

		/* LuCI removes options hidden by unsatisfied dependencies on save unless
		 * retain is enabled.  Toggling embedded Tailscale off must stop the
		 * backend without erasing its device, route, DNS, security or relay
		 * settings, so retain every real UCI option in this section. */
		for (const option of s.children) {
			if (option.option && !option.option.startsWith('_'))
				option.retain = true;
		}

		let statusRefreshPromise;
		function refreshTailscaleStatus() {
			if (statusRefreshPromise)
				return statusRefreshPromise;

			/* The backend status call executes several sing-box API commands. Keep
			 * it bounded so a hung API cannot block every later poll/focus refresh. */
			statusRefreshPromise = L.resolveDefault(resolveTailscaleStatus(4000, null), null).then((status) => {
				if (!status)
					return null;
				addPeerRouteChoices(status);
				addExitNodeChoices(status);
				const account = document.getElementById('tailscale_account');
				const statusView = document.getElementById('tailscale_status');
				if (account)
					dom.content(account, renderTailscaleAccountControl(status));
				if (statusView)
					dom.content(statusView,
						renderTailscaleStatus(status, configuredPeerRoutes, configuredAdvertiseRoutes, acceptRoutes));
				return status;
			}).finally(() => {
				statusRefreshPromise = null;
			});

			return statusRefreshPromise;
		}

		const refreshOnFocus = () => {
			if (document.hidden || !document.getElementById('tailscale_account'))
				return;
			refreshTailscaleStatus();
			refreshAdvertiseRouteChoices();
		};
		document.addEventListener('visibilitychange', refreshOnFocus);
		window.addEventListener('focus', refreshOnFocus);
		window.addEventListener('pageshow', refreshOnFocus);
		window.addEventListener('online', refreshOnFocus);
		/* The focus/visibility hooks below provide immediate refreshes; keep the
		 * background poll at the normal five-second cadence to avoid spawning the
		 * several embedded Tailscale API commands every second on small routers. */
		poll.add(refreshTailscaleStatus, 5);

		return m.render().then((node) => {
			/* The first status read is intentionally bounded so a slow router does
			 * not block LuCI. Populate choices once the form widget is available;
			 * subsequent poll cycles keep it current as Tailscale comes online. */
			addPeerRouteChoices(tailscaleStatus);
			addAdvertiseRouteChoices(localAdvertiseSubnets);
			addExitNodeChoices(tailscaleStatus);
			/* The view inserts the resolved map into #view after this callback;
			 * defer the first live refresh one turn so getUIElement() can find the
			 * rendered widgets as well as the account/status containers. */
			window.setTimeout(() => {
				refreshTailscaleStatus();
				refreshAdvertiseRouteChoices();
			}, 0);
			return E([ E('style', [ tailscaleStatusStyle ]), node ]);
		});
	}
});
