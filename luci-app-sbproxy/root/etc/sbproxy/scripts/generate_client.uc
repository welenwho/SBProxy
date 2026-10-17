#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile, popen } from 'fs';
import { isnan } from 'math';
import { connect } from 'ubus';
import { ingressEnabled } from 'ingress';
import { renderRouteMatch } from 'route_match';
import { loadDomainGroups, domainGroupOverlap } from 'domain_groups';
import { cursor } from 'uci';

import {
	createNodeLabelRegistry, filterExistingNodes, hasForceProxyRules, isEmpty,
	normalizeList, parseDnsServerAddress, resolveRoutingPorts,
	resolveUrltestNodes,
	reserveUniqueLabel, strToBool, strToInt, strToTime,
	removeBlankAttrs, renderEndpoint, renderOutbound, renderNodeDomainResolver,
	resolveNodeDialFields,
	SB_DIR, RUN_DIR
} from 'sbproxy';

const ubus = connect();

/* UCI config start */
const uci_config_dir = getenv('SBPROXY_UCI_CONFIG_DIR');
const uci = uci_config_dir ? cursor(uci_config_dir) : cursor();

const uciconfig = 'sbproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      ucicontrol = 'control',
      ucitailscale = 'tailscale';

const ucidnssetting = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule';

const uciroutingsetting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule';

const ucinode = 'node';
const uciruleset = 'ruleset';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
const tailscale_enabled = uci.get(uciconfig, ucitailscale, 'enabled') === '1';
const outbound_tags = createNodeLabelRegistry();
const node_outbound_tags = {};
const routing_outbound_tags = {};

uci.foreach(uciconfig, ucinode, (cfg) => {
	node_outbound_tags[cfg['.name']] = reserveUniqueLabel(
		outbound_tags,
		cfg.label, `cfg-${cfg['.name']}-out`
	);
});
uci.foreach(uciconfig, uciroutingnode, (cfg) => {
	routing_outbound_tags[cfg['.name']] = reserveUniqueLabel(
		outbound_tags,
		cfg.label, `cfg-${cfg['.name']}-out`
	);
});

function get_node_outbound_tag(section_id) {
	return node_outbound_tags[section_id] || `cfg-${section_id}-out`;
}

function get_routing_outbound_tag(section_id) {
	return routing_outbound_tags[section_id] || `cfg-${section_id}-out`;
}

function render_domain_rules(domains) {
	let suffixes = [], keywords = [];

	for (let domain in domains) {
		domain = trim(domain);
		if (!domain)
			continue;

		push(match(domain, /\./) ? suffixes : keywords, domain);
	}

	let rules = [];
	if (length(suffixes))
		push(rules, { domain_suffix: suffixes });
	if (length(keywords))
		push(rules, { domain_keyword: keywords });

	return rules;
}

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode === 'global') ? '9.9.9.9' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

let main_node, default_outbound, default_outbound_dns,
    domain_strategy, dns_server, china_dns_server, dns_default_strategy,
    dns_default_server, dns_disable_cache, dns_disable_cache_expire,
    dns_client_subnet, dns_optimistic, dns_optimistic_timeout, dns_cache_capacity,
    dns_timeout, cache_file_store_dns,
    direct_domain_list = [], proxy_domain_list = [];

dns_disable_cache = uci.get(uciconfig, ucimain, 'dns_disable_cache');
dns_disable_cache_expire = uci.get(uciconfig, ucimain, 'dns_disable_cache_expire');
dns_optimistic = uci.get(uciconfig, ucimain, 'dns_optimistic');
dns_optimistic_timeout = uci.get(uciconfig, ucimain, 'dns_optimistic_timeout');
dns_cache_capacity = uci.get(uciconfig, ucimain, 'dns_cache_capacity');
dns_timeout = uci.get(uciconfig, ucimain, 'dns_timeout');

if (routing_mode === 'disabled') {
	// Do not load proxy nodes, custom DNS or diversion rules in Tailscale-only
	// mode. Retain their UCI values so enabling the proxy restores the setup.
	main_node = 'nil';
	dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;
} else if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

	dns_server = uci.get(uciconfig, ucimain, 'dns_server');
	if (isEmpty(dns_server) || dns_server === 'wan')
		dns_server = wan_dns;

	if (routing_mode === 'bypass_mainland_china') {
		china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
		if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
			china_dns_server = wan_dns;
	}
	dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

	const direct_domain_content = trim(readfile(SB_DIR + '/resources/direct_list.txt'));
	if (direct_domain_content)
		direct_domain_list = split(direct_domain_content, /[\r\n]/);

	if (routing_mode === 'bypass_mainland_china') {
		const proxy_domain_content = trim(readfile(SB_DIR + '/resources/proxy_list.txt'));
		if (proxy_domain_content)
			proxy_domain_list = split(proxy_domain_content, /[\r\n]/);
	}

} else {
	/* DNS settings */
	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy');
	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server');
	dns_client_subnet = uci.get(uciconfig, ucidnssetting, 'client_subnet');
	cache_file_store_dns = uci.get(uciconfig, ucidnssetting, 'cache_file_store_dns');

	/* Routing settings */
	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
	default_outbound_dns = uci.get(uciconfig, uciroutingsetting, 'default_outbound_dns') || 'default-dns';
	domain_strategy = uci.get(uciconfig, uciroutingsetting, 'domain_strategy');
}

const default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface'),
      listen_interfaces = normalizeList(uci.get(uciconfig, ucicontrol, 'listen_interfaces'));

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';
const clash_api_port = strToInt(uci.get(uciconfig, uciinfra, 'clash_api_port'));

const tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
const tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
const tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
const tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
const tcpip_stack = (routing_mode === 'custom' ?
	uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') : uci.get(uciconfig, ucimain, 'tcpip_stack')) ||
	uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') || 'mixed';
const udp_timeout = uci.get(uciconfig, routing_mode === 'custom' ? uciroutingsetting : uciinfra, 'udp_timeout');

const log_level = uci.get(uciconfig, ucimain, 'log_level') || 'warn';
const dashboard_path = SB_DIR + '/dashboard';
const dashboard_enabled = routing_mode !== 'disabled' &&
      uci.get(uciconfig, ucimain, 'dashboard_enabled') === '1' &&
      !isEmpty(readfile(dashboard_path + '/index.html')),
      dashboard_port = strToInt(uci.get(uciconfig, ucimain, 'dashboard_port')),
      dashboard_secret = uci.get(uciconfig, ucimain, 'dashboard_secret');
const dashboard_tls_tailscale = dashboard_enabled &&
      uci.get(uciconfig, ucimain, 'dashboard_tls_tailscale') === '1';
const memory_guard_enabled = uci.get(uciconfig, ucimain, 'memory_guard_enabled') === '1';
const memory_guard_limit = uci.get(uciconfig, ucimain, 'memory_guard_limit');
const memory_guard_safety_margin = uci.get(uciconfig, ucimain, 'memory_guard_safety_margin');
const domain_groups = isEmpty(main_node) ? [] : loadDomainGroups(uci, uciconfig, routing_mode);
const groups_need_sniff = length(filter(domain_groups, (g) => g.needs_sniff)) > 0;
const overlap = domainGroupOverlap(domain_groups);
if (overlap) warn('Diversion groups overlap at ' + overlap + '; first group wins.\n');
function group_outbound(group) {
	if (group.node === '_direct') return 'direct-out';
	if (group.node === '_main' || group.node === main_node) return 'main-out';
	return get_node_outbound_tag(group.node);
}
function group_match(group) { return group.match; }

const force_proxy_rules = hasForceProxyRules(uci, uciconfig, proxy_domain_list) ||
	groups_need_sniff || length(filter(domain_groups, (g) => g.node !== '_direct')) > 0;
const fast_bypass_mainland = routing_mode === 'bypass_mainland_china' && !force_proxy_rules;
const proxy_client_enabled = !isEmpty(main_node) || !isEmpty(default_outbound);
const ingress_enabled = proxy_client_enabled && ingressEnabled(uci.get_all(uciconfig, ucicontrol));
const ingress_dns_port = strToInt(uci.get(uciconfig, uciinfra, 'ingress_dns_port'));
if (ingress_enabled && (!ingress_dns_port || ingress_dns_port === int(dns_port)))
	die('Ingress DNS port is unavailable or conflicts with the normal DNS listener.');

let tailscale_auth_key = uci.get(uciconfig, ucitailscale, 'auth_key');
const tailscale_auth_key_file = uci.get(uciconfig, ucitailscale, 'auth_key_file');
if (tailscale_enabled && !isEmpty(tailscale_auth_key_file)) {
	if (!match(tailscale_auth_key_file, /^\//))
		die('Tailscale auth key file must use an absolute path.');
	tailscale_auth_key = trim(readfile(tailscale_auth_key_file) || '');
	if (!tailscale_auth_key)
		die('Tailscale auth key file is empty or unavailable.');
}
const tailscale_magic_dns = tailscale_enabled &&
      uci.get(uciconfig, ucitailscale, 'magic_dns') !== '0';
const tailscale_api_port = strToInt(uci.get(uciconfig, uciinfra, 'tailscale_api_port'));
const tailscale_endpoint_tag = 'sbproxy-tailscale';
const tailscale_dns_tag = 'sbproxy-tailscale-dns';
const tailscale_exit_node = uci.get(uciconfig, ucitailscale, 'exit_node');
const tailscale_use_exit_node = tailscale_enabled && !isEmpty(tailscale_exit_node);
const tailscale_disable_snat = uci.get(uciconfig, ucitailscale, 'disable_snat_subnet_routes') === '1';
const tailscale_ssh_enabled = uci.get(uciconfig, ucitailscale, 'ssh_server') === '1';
const derp_server_enabled = tailscale_enabled &&
      uci.get(uciconfig, ucitailscale, 'derp_server_enabled') === '1';
const tailscale_endpoint = tailscale_enabled ? {
	type: 'tailscale',
	tag: tailscale_endpoint_tag,
	state_directory: uci.get(uciconfig, ucitailscale, 'state_directory') ||
		SB_DIR + '/tailscale',
	auth_key: tailscale_auth_key,
	control_url: uci.get(uciconfig, ucitailscale, 'control_url'),
	domain_resolver: {
		server: 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	},
	ephemeral: strToBool(uci.get(uciconfig, ucitailscale, 'ephemeral')),
	hostname: uci.get(uciconfig, ucitailscale, 'hostname'),
	/* OpenWrt policy rules expose only the peer routes selected in subnet_routes. */
	accept_routes: strToBool(uci.get(uciconfig, ucitailscale, 'accept_routes')),
	exit_node: tailscale_exit_node,
	exit_node_allow_lan_access: strToBool(
		uci.get(uciconfig, ucitailscale, 'exit_node_allow_lan_access')
	),
	advertise_routes: normalizeList(
		uci.get(uciconfig, ucitailscale, 'advertise_routes')
	),
	advertise_exit_node: strToBool(
		uci.get(uciconfig, ucitailscale, 'advertise_exit_node')
	),
	advertise_tags: normalizeList(
		uci.get(uciconfig, ucitailscale, 'advertise_tags')
	),
	listen_port: strToInt(uci.get(uciconfig, ucitailscale, 'listen_port')),
	relay_server_port: uci.get(uciconfig, ucitailscale, 'relay_server_enabled') === '1' ?
		int(uci.get(uciconfig, ucitailscale, 'relay_server_port') || 0) : null,
	relay_server_static_endpoints:
		uci.get(uciconfig, ucitailscale, 'relay_server_enabled') === '1' ?
		normalizeList(uci.get(uciconfig, ucitailscale, 'relay_server_static_endpoints')) : null,
	system_interface: true,
	system_interface_name: uci.get(uciconfig, ucitailscale, 'system_interface_name') ||
		'tailscale0',
	system_interface_mtu: strToInt(
		uci.get(uciconfig, ucitailscale, 'system_interface_mtu')
	),
	udp_timeout: strToTime(uci.get(uciconfig, ucitailscale, 'udp_timeout')),
	bind_interface: uci.get(uciconfig, ucitailscale, 'bind_interface'),
	ssh_server: tailscale_ssh_enabled ? {
		enabled: true,
		disable_pty: strToBool(uci.get(uciconfig, ucitailscale, 'ssh_disable_pty')),
		disable_sftp: strToBool(uci.get(uciconfig, ucitailscale, 'ssh_disable_sftp')),
		disable_forwarding: strToBool(
			uci.get(uciconfig, ucitailscale, 'ssh_disable_forwarding')
		)
	} : null,
	taildrop_directory: uci.get(uciconfig, ucitailscale, 'taildrop_enabled') === '1' ?
		(uci.get(uciconfig, ucitailscale, 'taildrop_directory') ||
		 SB_DIR + '/tailscale/Taildrop') : null
} : null;
if (dashboard_tls_tailscale && !tailscale_enabled)
	die('The Tailscale dashboard certificate requires embedded Tailscale.');
if (tailscale_endpoint?.advertise_exit_node && !isEmpty(tailscale_endpoint?.exit_node))
	die('Tailscale cannot advertise and use an exit node at the same time.');
if (tailscale_endpoint?.advertise_exit_node && tailscale_disable_snat)
	die('Tailscale cannot preserve subnet source addresses while advertising an exit node.');
/* UCI config end */

/* Config helper start */
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function merge_control_options(options) {
	let values = [];
	for (let option in options) {
		if (!option)
			continue;
		values = [...values, ...normalizeList(uci.get(uciconfig, ucicontrol, option))];
	}
	return values;
}

function normalize_cidrs(values) {
	return map(values, (value) => match(value, /\//) ? value : `${value}/${match(value, /:/) ? 128 : 32}`);
}

function unique_cidrs(values) {
	let unique = [], seen = {};
	for (let route in normalize_cidrs(values)) {
		if (!seen[route]) {
			seen[route] = true;
			push(unique, route);
		}
	}
	return unique;
}

function read_command(command) {
	const fd = popen(command);
	if (!fd)
		return '';

	let payload = '', line;
	for (line = fd.read('line'); length(line); line = fd.read('line'))
		payload += line;
	fd.close();
	return payload;
}

function tailscale_route_exclusions() {
	let routes = [ '100.64.0.0/10' ];
	if (ipv6_support === '1')
		push(routes, 'fd7a:115c:a1e0::/48');

	uci.load('tailscale');
	routes = [
		...routes,
		...normalizeList(uci.get('tailscale', 'settings', 'subnet_routes')),
		...normalizeList(uci.get(uciconfig, ucitailscale, 'subnet_routes'))
	];

	const families = (ipv6_support === '1') ? [ '-4', '-6' ] : [ '-4' ];
	for (let family in families) {
		let entries;
		try {
			entries = json(read_command(`/sbin/ip -j ${family} route show table 52 2>"/dev/null"`));
		} catch (e) {
			continue;
		}
		if (type(entries) !== 'array')
			continue;

		for (let entry in entries) {
			const destination = trim(entry?.dst || '');
			if (!match(entry?.dev || '', /^tailscale[0-9]+$/) ||
			    !destination || destination === 'default' ||
			    destination === '0.0.0.0/0' || destination === '::/0' ||
			    destination === '0.0.0.0/1' || destination === '128.0.0.0/1' ||
			    destination === '::/1' || destination === '8000::/1')
				continue;
			push(routes, destination);
		}
	}

	return unique_cidrs(routes);
}

function source_match(ipv4_option, ipv6_option, mac_option) {
	const ips = normalize_cidrs(merge_control_options([ipv4_option, ipv6_option]));
	const macs = merge_control_options([mac_option]);
	let rules = [];

	if (length(ips))
		push(rules, { source_ip_cidr: ips });
	if (length(macs))
		push(rules, { source_mac_address: macs });

	if (length(rules) === 1)
		return rules[0];
	if (length(rules) > 1)
		return { type: 'logical', mode: 'or', rules };
	return null;
}

function destination_match(ipv4_option, ipv6_option) {
	const ips = normalize_cidrs(merge_control_options([ipv4_option, ipv6_option]));
	return length(ips) ? { ip_cidr: ips } : null;
}

function routing_port_match() {
	const ports_config = resolveRoutingPorts(
		uci.get(uciconfig, ucimain, 'routing_port'),
		uci.get(uciconfig, uciinfra, 'common_port'),
		uci.get(uciconfig, ucimain, 'routing_port_extra')
	);
	if (!length(ports_config))
		return null;

	let ports = [], ranges = [], rules = [];
	for (let item in ports_config) {
		if (match(item, /-/))
			push(ranges, replace(item, '-', ':'));
		else
			push(ports, int(item));
	}
	if (length(ports))
		push(rules, { port: ports });
	if (length(ranges))
		push(rules, { port_range: ranges });

	if (length(rules) === 1)
		return rules[0];
	if (length(rules) > 1)
		return { type: 'logical', mode: 'or', rules };
	return null;
}

function push_route(rules, match_rule, outbound, invert) {
	if (!match_rule)
		return;
	push(rules, {
		...match_rule,
		invert: invert ? true : match_rule.invert,
		action: 'route',
		outbound
	});
}

function push_bypass(rules, match_rule) {
	if (!match_rule)
		return;
	push(rules, {
		...match_rule,
		action: 'bypass'
	});
}

function tun_match(match_rule) {
	if (!match_rule)
		return null;
	return {
		type: 'logical',
		mode: 'and',
		rules: [
			{ inbound: 'tun-in' },
			match_rule
		]
	};
}

function get_control_matches() {
	const included_ports = routing_port_match();
	const proxy_policy_mode = routing_mode in ['bypass_mainland_china', 'custom'];

	return {
		direct_source: source_match('lan_direct_ipv4_ips', null, 'lan_direct_mac_addrs'),
		proxy_source: proxy_policy_mode ? source_match('lan_proxy_ipv4_ips', null, 'lan_proxy_mac_addrs') : null,
		wan_proxy: proxy_policy_mode ? destination_match('wan_proxy_ipv4_ips', 'wan_proxy_ipv6_ips') : null,
		wan_direct: destination_match('wan_direct_ipv4_ips', 'wan_direct_ipv6_ips'),
		bypass_ports: included_ports ? { ...included_ports, invert: true } : null
	};
}

function add_control_pre_match_rules(rules, proxy_outbound) {
	const control = get_control_matches();

	push_bypass(rules, tun_match(control.direct_source));

	if (proxy_outbound) {
		push_route(rules, tun_match(control.proxy_source), proxy_outbound);
		push_route(rules, tun_match(control.wan_proxy), proxy_outbound);
	}
	push_bypass(rules, tun_match(control.wan_direct));
	push_bypass(rules, tun_match({ ip_is_private: true }));
	push_bypass(rules, tun_match(control.bypass_ports));
}

function add_control_rules(rules, proxy_outbound) {
	const control = get_control_matches();

	push_route(rules, control.direct_source, 'direct-out');

	if (proxy_outbound) {
		push_route(rules, control.proxy_source, proxy_outbound);
		push_route(rules, control.wan_proxy, proxy_outbound);
	}
	push_route(rules, control.wan_direct, 'direct-out');
	push(rules, { ip_is_private: true, action: 'route', outbound: 'direct-out' });
	push_route(rules, control.bypass_ports, 'direct-out');
}

function has_mac_control() {
	return length(merge_control_options([
		'lan_direct_mac_addrs',
		(routing_mode in ['bypass_mainland_china', 'custom']) ? 'lan_proxy_mac_addrs' : null
	])) > 0;
}

function add_mainland_rule_sets(rule_sets) {
	push(rule_sets, {
		type: 'local',
		tag: 'geoip-cn',
		format: 'binary',
		path: SB_DIR + '/resources/geoip_cn.srs'
	});
	push(rule_sets, {
		type: 'local',
		tag: 'geosite-cn',
		format: 'binary',
		path: SB_DIR + '/resources/geosite_cn.srs'
	});
}

function parse_dnsquery(strquery) {
	if (type(strquery) !== 'array' || isEmpty(strquery))
		return null;

	let querys = [];
	for (let i in strquery)
		isnan(int(i)) ? push(querys, i) : push(querys, int(i));

	return querys;

}

function render_dns_rule_match(cfg) {
	return {
		ip_version: strToInt(cfg.ip_version),
		query_type: parse_dnsquery(cfg.query_type),
		network: cfg.network,
		protocol: cfg.protocol,
		domain: cfg.domain,
		domain_suffix: cfg.domain_suffix,
		domain_keyword: cfg.domain_keyword,
		domain_regex: cfg.domain_regex,
		port: parse_port(cfg.port),
		port_range: cfg.port_range,
		source_ip_cidr: cfg.source_ip_cidr,
		source_ip_is_private: strToBool(cfg.source_ip_is_private),
		source_port: parse_port(cfg.source_port),
		source_port_range: cfg.source_port_range,
		process_name: cfg.process_name,
		process_path: cfg.process_path,
		process_path_regex: cfg.process_path_regex,
		user: cfg.user
	};
}

function get_outbound(cfg) {
	if (isEmpty(cfg))
		return null;

	if (type(cfg) === 'array') {
		if ('any-out' in cfg)
			return 'any';

		let outbounds = [];
		for (let i in cfg)
			push(outbounds, get_outbound(i));
		return outbounds;
	} else {
		switch (cfg) {
		case 'direct-out':
			return cfg;
		default:
			const node = uci.get(uciconfig, cfg, 'node');
			if (isEmpty(node))
				die(sprintf("%s's node is missing, please check your configuration.", cfg));
			else if (node === 'urltest')
				return get_routing_outbound_tag(cfg);
			else
				return get_node_outbound_tag(node);
		}
	}
}

function get_resolver(cfg) {
	if (isEmpty(cfg))
		return null;

	switch (cfg) {
	case 'default-dns':
	case 'system-dns':
		return cfg;
	default:
		return 'cfg-' + cfg + '-dns';
	}
}

function resolve_node_dns(name) {
	if (name && !(name in ['default-dns', 'system-dns', 'china-dns'])) {
		const server = uci.get_all(uciconfig, name);
		if (routing_mode !== 'custom' || server?.['.type'] !== ucidnsserver || server.enabled !== '1')
			die(sprintf('Node DNS resolver %s is not available in %s mode.', name, routing_mode));
	}
	return name === 'china-dns' ? name : get_resolver(name);
}

function render_node_dial(outbound, node) {
	if (!outbound) return null;
	const resolved = resolveNodeDialFields(uci, uciconfig, node);
	if (resolved.conflict)
		die(sprintf('Conflicting legacy %s for node %s; set it on the node or split the node.',
			resolved.conflict, node['.name']));
	const effective = resolved.node;
	const fallback = !isEmpty(main_node) ?
		(routing_mode === 'bypass_mainland_china' ? 'china-dns' : 'default-dns') :
		(default_outbound_dns || 'default-dns');
	outbound.bind_interface = effective.bind_interface;
	outbound.domain_resolver = renderNodeDomainResolver(effective, resolve_node_dns, fallback);
	return outbound;
}

function generate_outbound(node) {
	const outbound = render_node_dial(renderOutbound(node), node);
	if (outbound && node['.name'])
		outbound.tag = get_node_outbound_tag(node['.name']);
	return outbound;
}

function generate_endpoint(node) {
	const endpoint = render_node_dial(renderEndpoint(node), node);
	if (endpoint && node['.name'])
		endpoint.tag = get_node_outbound_tag(node['.name']);
	return endpoint;
}

function render_rule_set(cfg, outbound) {
	return {
		type: cfg.type, tag: 'cfg-' + cfg['.name'] + '-rule', format: cfg.format,
		path: cfg.path, url: cfg.url,
		http_client: outbound === 'direct-out' ? 'direct-http' : (outbound ? { detour: outbound } : null),
		update_interval: cfg.update_interval
	};
}

function get_ruleset(cfg) {
	if (isEmpty(cfg))
		return null;

	let rules = [];
	for (let i in cfg)
		push(rules, isEmpty(i) ? null : 'cfg-' + i + '-rule');
	return rules;
}

function add_tailscale_exit_node_rule(rules) {
	if (!tailscale_use_exit_node)
		return;

	/* Traffic received from the tailnet still follows SBProxy's normal rules.
	 * Only local and intercepted traffic may use the selected exit node. */
	push(rules, {
		inbound: tailscale_endpoint_tag,
		invert: true,
		action: 'route',
		outbound: tailscale_endpoint_tag
	});
}

function render_derp_mesh_peer(value) {
	value = trim(value || '');
	let parsed = match(value, /^\[([0-9A-Fa-f:]+)\]:(\d+)$/);
	if (!parsed)
		parsed = match(value, /^([^:]+):(\d+)$/);
	if (!parsed)
		return null;
	const port = int(parsed[2]);
	if (port < 1 || port > 65535)
		return null;
	return {
		server: parsed[1],
		server_port: port,
		host: parsed[1],
		tls: {
			enabled: true,
			server_name: parsed[1]
		},
		domain_resolver: 'default-dns'
	};
}

function render_derp_tls() {
	const mode = uci.get(uciconfig, ucitailscale, 'derp_tls_mode') || 'manual';
	if (mode === 'tailscale')
		return {
			enabled: true,
			certificate_provider: {
				type: 'tailscale',
				endpoint: tailscale_endpoint_tag
			}
		};
	if (mode === 'acme') {
		const domains = normalizeList(uci.get(uciconfig, ucitailscale, 'derp_acme_domain'));
		return {
			enabled: true,
			certificate_provider: {
				type: 'acme',
				domain: domains,
				data_directory: SB_DIR + '/certs/derp',
				default_server_name: domains[0],
				email: uci.get(uciconfig, ucitailscale, 'derp_acme_email'),
				provider: uci.get(uciconfig, ucitailscale, 'derp_acme_provider') ||
					'letsencrypt',
				alternative_http_port: strToInt(
					uci.get(uciconfig, ucitailscale, 'derp_acme_http_port')
				),
				alternative_tls_port: strToInt(
					uci.get(uciconfig, ucitailscale, 'derp_acme_tls_port')
				),
				http_client: 'direct-http'
			}
		};
	}
	return {
		enabled: true,
		certificate_path: uci.get(uciconfig, ucitailscale, 'derp_cert_path'),
		key_path: uci.get(uciconfig, ucitailscale, 'derp_key_path')
	};
}
/* Config helper end */

const config = {};

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* HTTP clients */
config.http_clients = [
	{
		tag: 'direct-http',
	}
];

/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: true,
		server: ntp_server,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};

/* DNS start */
/* Default settings */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: null
		},
		{
			tag: 'system-dns',
			type: 'local',
			detour: null
		}
	],
	rules: [],
	reverse_mapping: true,
	strategy: dns_default_strategy,
	disable_cache: strToBool(dns_disable_cache),
	disable_expire: strToBool(dns_disable_cache_expire),
	optimistic: (!strToBool(dns_disable_cache) && !strToBool(dns_disable_cache_expire) &&
		dns_optimistic === '1') ? (dns_optimistic_timeout ? {
			enabled: true,
			timeout: strToTime(dns_optimistic_timeout)
		} : true) : null,
	cache_capacity: strToInt(dns_cache_capacity),
	timeout: strToTime(dns_timeout),
	client_subnet: dns_client_subnet
};

if (tailscale_magic_dns) {
	push(config.dns.servers, {
		tag: tailscale_dns_tag,
		type: 'tailscale',
		endpoint: tailscale_endpoint_tag,
		accept_default_resolvers: false,
		accept_search_domain: uci.get(uciconfig, ucitailscale, 'accept_search_domain') !== '0'
	});
	push(config.dns.rules, {
		preferred_by: tailscale_dns_tag,
		action: 'route',
		server: tailscale_dns_tag
	});
}

// Route bypass-source DNS before user proxy DNS rules. Keep local names and
// reverse lookup with dnsmasq, and preserve the preferred Tailscale DNS rule.
if (ingress_enabled) {
	push(config.dns.servers, {
		tag: 'ingress-local-dns', type: 'udp', server: '127.0.0.1',
		server_port: int(uci.get('dhcp', '@dnsmasq[0]', 'port') || '53'), detour: 'direct-out'
	});
	const local_domain = uci.get('dhcp', '@dnsmasq[0]', 'domain') || 'lan';
	push(config.dns.rules,
		{ inbound: ['ingress-dns-in'], domain_suffix: [local_domain, 'in-addr.arpa', 'ip6.arpa'],
		  action: 'route', server: 'ingress-local-dns', disable_cache: true },
		{ inbound: ['ingress-dns-in'], domain_regex: ['^[^.]+\\.?$'],
		  action: 'route', server: 'ingress-local-dns', disable_cache: true },
		{ inbound: ['ingress-dns-in'], action: 'route', server: 'default-dns', disable_cache: true });
}

if (length(domain_groups)) {
	let group_resolvers = { 'main-out': 'main-dns' };
	for (let group in domain_groups) {
		// Do not broaden connection-only criteria into unrelated DNS matches.
		if (!group.dns_match) continue;
		if (group.node === '_reject') {
			push(config.dns.rules, { ...group.dns_match, action: 'predefined', rcode: 'REFUSED' });
			continue;
		}
		const outbound = group_outbound(group);
		let server = 'default-dns';
		if (outbound !== 'direct-out') {
			server = group_resolvers[outbound];
			if (!server) {
				server = 'diversion-' + group.id + '-dns';
				group_resolvers[outbound] = server;
				push(config.dns.servers, {
					tag: server, domain_resolver: 'default-dns', detour: outbound,
					...parseDnsServerAddress(dns_server, 'tcp')
				});
			}
		}
		push(config.dns.rules, { ...group.dns_match, action: 'route', server });
	}
}

if (!isEmpty(main_node)) {
	/* Main DNS */
	push(config.dns.servers, {
		tag: 'main-dns',
		domain_resolver: {
			server: 'default-dns',
			strategy: (ipv6_support !== '1') ? 'ipv4_only' : null
		},
		detour: 'main-out',
		...parseDnsServerAddress(dns_server, 'tcp')
	});
	config.dns.final = 'main-dns';

	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns'
		});

	/* Filter out SVCB/HTTPS queries for "exquisite" Apple devices */
	if (length(proxy_domain_list))
		push(config.dns.rules, {
			rule_set: 'proxy-domain',
			query_type: [64, 65],
			action: 'reject'
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.dns.servers, {
			tag: 'china-dns',
			domain_resolver: {
				server: 'default-dns',
				strategy: 'prefer_ipv6'
			},
			detour: null,
			...parseDnsServerAddress(china_dns_server)
		});

		if (length(proxy_domain_list))
			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});

		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns'
		});
		push(config.dns.rules, {
			action: 'evaluate',
			server: 'main-dns'
		});
		push(config.dns.rules, {
			rule_set: 'geoip-cn',
			match_response: true,
			action: 'route',
			server: 'china-dns'
		});
		push(config.dns.rules, {
			match_response: true,
			action: 'respond'
		});
		push(config.dns.rules, {
			action: 'route',
			server: 'china-dns'
		});
	}
} else if (!isEmpty(default_outbound)) {
	/* DNS servers */
	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		let outbound = get_outbound(cfg.outbound);
		if (outbound === 'direct-out')
			outbound = null;

		const remote_server = cfg.type in ['udp', 'tcp', 'tls', 'https', 'h3', 'quic'];
		push(config.dns.servers, {
			tag: 'cfg-' + cfg['.name'] + '-dns',
			type: cfg.type,
			server: remote_server ? cfg.server : null,
			server_port: remote_server ? strToInt(cfg.server_port) : null,
			interface: cfg.type === 'dhcp' ? cfg.interface : null,
			path: remote_server ? cfg.path : null,
			headers: remote_server ? cfg.headers : null,
			tls: remote_server && cfg.tls_sni ? {
				enabled: true,
				server_name: cfg.tls_sni
			} : null,
			domain_resolver: remote_server && (cfg.domain_resolver || cfg.domain_strategy) ? {
				server: get_resolver(cfg.domain_resolver || dns_default_server),
				strategy: cfg.domain_strategy
			} : null,
			detour: outbound
		});
	});

	/* DNS rules */
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		const action = cfg.action || 'route';
		const match_response = strToBool(cfg.match_response) ||
			!isEmpty(cfg.ip_cidr) || strToBool(cfg.ip_is_private);
		const match_fields = render_dns_rule_match(cfg);

		if (match_response)
			push(config.dns.rules, {
				...match_fields,
				action: 'evaluate',
				server: get_resolver(cfg.evaluate_server || dns_default_server)
			});

		push(config.dns.rules, {
			...match_fields,
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			match_response: match_response,
			invert: strToBool(cfg.invert),
			action: action,
			server: (action in ['route', 'evaluate']) ? get_resolver(cfg.server) : null,
			disable_cache: (action in ['route', 'evaluate', 'route-options']) ? strToBool(cfg.dns_disable_cache) : null,
			disable_optimistic_cache: (action in ['route', 'evaluate', 'route-options']) ?
				strToBool(cfg.dns_disable_optimistic_cache) : null,
			rewrite_ttl: (action in ['route', 'evaluate', 'route-options']) ? strToInt(cfg.rewrite_ttl) : null,
			timeout: (action in ['route', 'evaluate', 'route-options']) ? strToTime(cfg.dns_timeout) : null,
			client_subnet: (action in ['route', 'evaluate', 'route-options']) ? cfg.client_subnet : null,
			method: (action === 'reject') ? cfg.reject_method : null,
			no_drop: (action === 'reject') ? strToBool(cfg.reject_no_drop) : null,
			rcode: (action === 'predefined') ? cfg.predefined_rcode : null,
			answer: (action === 'predefined') ? cfg.predefined_answer : null,
			ns: (action === 'predefined') ? cfg.predefined_ns : null,
			extra: (action === 'predefined') ? cfg.predefined_extra : null
		});
	});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	config.dns.final = get_resolver(dns_default_server);
} else if (tailscale_enabled) {
	config.dns.final = 'default-dns';
}
/* DNS end */

/* Inbound start */
config.inbounds = [];
if (ingress_enabled)
	push(config.inbounds, { type: 'direct', tag: 'ingress-dns-in', listen: '::', listen_port: ingress_dns_port });

if (proxy_client_enabled || tailscale_magic_dns)
	push(config.inbounds, {
		type: 'direct',
		tag: 'dns-in',
		listen: '::',
		listen_port: int(dns_port)
	});

if (proxy_client_enabled)
	push(config.inbounds, {
		type: 'mixed',
		tag: 'mixed-in',
		listen: '::',
		listen_port: int(mixed_port),
		udp_timeout: strToTime(udp_timeout),
		set_system_proxy: false
	});

if (proxy_client_enabled) {
	const route_exclude_address = filter(unique_cidrs([
		...normalizeList(uci.get(uciconfig, ucimain, 'tun_route_exclude_ipv4_ips')),
		...normalizeList(uci.get(uciconfig, ucimain, 'tun_route_exclude_ipv6_ips')),
		...(strToBool(uci.get(uciconfig, ucimain, 'tun_route_exclude_tailscale')) ? tailscale_route_exclusions() : [])
	]), (address) => !match(address, /\/0$/));
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',

		interface_name: tun_name,
		address: (ipv6_support === '1') ? [tun_addr4, tun_addr6] : [tun_addr4],
		mtu: strToInt(tun_mtu),
		auto_route: true,
		auto_redirect: true,
		/* Pin the bypass mark used by the optional ingress firewall. */
		auto_redirect_output_mark: ingress_enabled ? 8228 : null,
		/* dnsmasq already redirects LAN DNS to dns-in; avoid an earlier TUN DNAT. */
		dns_mode: 'disabled',
		route_exclude_address: length(route_exclude_address) ? route_exclude_address : null,
		route_exclude_address_set: fast_bypass_mainland ? ['geoip-cn'] : null,
		include_interface: length(listen_interfaces) ? listen_interfaces : null,
		udp_timeout: strToTime(udp_timeout),
		stack: tcpip_stack
	});
}
/* Inbound end */

/* Outbound start */
config.endpoints = [];
if (tailscale_endpoint)
	push(config.endpoints, tailscale_endpoint);

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
	}
];
let emitted_nodes = {};
function emit_node(entry, endpoint) {
	const signature = sprintf('%J', removeBlankAttrs(entry));
	if (entry.tag in emitted_nodes) {
		if (emitted_nodes[entry.tag] !== signature)
			die(sprintf('Node %s has conflicting routing contexts; split the node.', entry.tag));
		return;
	}
	emitted_nodes[entry.tag] = signature;
	push(endpoint ? config.endpoints : config.outbounds, entry);
}
/* Smart selection keeps the same routing tags and candidate resolution as URLTest. */
const smart_groups = [];
function selection_group(group, enabled, bandwidth) {
	group.interval ||= '60s';
	group.tolerance ??= 75;
	if (!enabled) return group;
	const fallback = reserveUniqueLabel(outbound_tags, `${group.tag}-smart-fallback`, 'smart-fallback');
	push(config.outbounds, { ...group, tag: fallback });
	push(smart_groups, {
		tag: group.tag, nodes: group.outbounds, fallback,
		bandwidth
	});
	return {
		type: 'selector', tag: group.tag, outbounds: [fallback, ...group.outbounds],
		default: fallback, interrupt_exist_connections: group.interrupt_exist_connections
	};
}
/* Main outbounds */
if (!isEmpty(main_node)) {
	let urltest_nodes = [];

	if (main_node === 'urltest') {
		const main_urltest_nodes = resolveUrltestNodes(
			uci, uciconfig,
			uci.get(uciconfig, ucimain, 'main_urltest_nodes'),
			uci.get(uciconfig, ucimain, 'main_urltest_subscriptions')
		);
		if (!length(main_urltest_nodes))
			die('Main URLTest group has no available nodes.');
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval') || '60';
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance') ?? '75';
		const main_urltest_interrupt = uci.get(uciconfig, ucimain, 'main_urltest_interrupt_exist_connections') || '0';

		push(config.outbounds, selection_group({
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => get_node_outbound_tag(k)),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
			interrupt_exist_connections: strToBool(main_urltest_interrupt)
		}, uci.get(uciconfig, ucimain, 'main_urltest_smart') === '1',
		   uci.get(uciconfig, ucimain, 'main_urltest_smart_bandwidth') !== '0'));
		urltest_nodes = main_urltest_nodes;
	} else {
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
		if (main_node_cfg.type === 'wireguard') {
			const main_endpoint = generate_endpoint(main_node_cfg);
			if (main_endpoint) {
				main_endpoint.tag = 'main-out';
				emit_node(main_endpoint, true);
			}
		} else {
			const main_outbound = generate_outbound(main_node_cfg);
			if (main_outbound) {
				main_outbound.tag = 'main-out';
				emit_node(main_outbound, false);
			}
		}
	}

	for (let i in urltest_nodes) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = generate_endpoint(urltest_node);
			if (endpoint)
				emit_node(endpoint, true);
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound)
				emit_node(outbound, false);
		}
	}
} else if (!isEmpty(default_outbound)) {
	let urltest_nodes = [];

	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		if (cfg.node === 'urltest') {
			const urltest_list = resolveUrltestNodes(
				uci, uciconfig, cfg.urltest_nodes, cfg.urltest_subscriptions
			);
			if (!length(urltest_list))
				die(sprintf('Routing URLTest group %s has no available nodes.', cfg['.name']));
			push(config.outbounds, selection_group({
				type: 'urltest',
				tag: get_routing_outbound_tag(cfg['.name']),
				outbounds: map(urltest_list, (k) => get_node_outbound_tag(k)),
				url: cfg.urltest_url,
				interval: strToTime(cfg.urltest_interval || '60'),
				tolerance: strToInt(cfg.urltest_tolerance ?? '75'),
				idle_timeout: strToTime(cfg.urltest_idle_timeout),
				interrupt_exist_connections: strToBool(cfg.urltest_interrupt_exist_connections || '0')
			}, cfg.urltest_smart === '1', cfg.urltest_smart_bandwidth !== '0'));
			urltest_nodes = [...urltest_nodes, ...filter(urltest_list, (l) => !~index(urltest_nodes, l))];
		} else {
			const outbound = uci.get_all(uciconfig, cfg.node) || {};
			if (isEmpty(outbound))
				return;

			if (outbound.type === 'wireguard') {
				const endpoint = generate_endpoint(outbound);
				if (!endpoint)
					return;

				endpoint.detour = get_outbound(cfg.outbound);
				if (endpoint.detour) {
					endpoint.bind_interface = null;
					endpoint.domain_resolver = null;
				}
				emit_node(endpoint, true);
			} else {
				const routed_outbound = generate_outbound(outbound);
				if (!routed_outbound)
					return;

				routed_outbound.detour = get_outbound(cfg.outbound);
				if (routed_outbound.detour) {
					routed_outbound.bind_interface = null;
					routed_outbound.domain_resolver = null;
				}
				emit_node(routed_outbound, false);
			}
		}
	});

	/* Re-render URLTest members even if a direct route already emitted the tag:
	 * emit_node verifies the effective dial definition before de-duplicating. */
	for (let i in urltest_nodes) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = generate_endpoint(urltest_node);
			if (endpoint)
				emit_node(endpoint, true);
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound)
				emit_node(outbound, false);
		}
	}

}

for (let group in domain_groups) {
	if (group.node === '_reject') continue;
	const tag = group_outbound(group);
	if (length(filter([...config.outbounds, ...config.endpoints], (out) => out.tag === tag))) continue;
	const node = uci.get_all(uciconfig, group.node);
	const entry = node.type === 'wireguard' ? generate_endpoint(node) : generate_outbound(node);
	if (!entry) die('Unable to render diversion node: ' + group.node);
	emit_node(entry, node.type === 'wireguard');
}

if (isEmpty(config.endpoints))
	config.endpoints = null;
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [],
	rule_set: [],
	auto_detect_interface: isEmpty(default_interface) ? true : null,
	default_interface: default_interface,
	find_neighbor: has_mac_control() ? true : null
};
config.route.default_http_client = 'direct-http';
if (proxy_client_enabled || tailscale_magic_dns)
	push(config.route.rules, {
		inbound: 'dns-in',
		action: 'hijack-dns'
	});
if (ingress_enabled)
	push(config.route.rules, { inbound: 'ingress-dns-in', action: 'hijack-dns' });
if (tailscale_enabled)
	push(config.route.rules, {
		preferred_by: tailscale_endpoint_tag,
		action: 'route',
		outbound: tailscale_endpoint_tag
	});
/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

	/* Device/port exceptions are authoritative. Domain groups follow list order. */
	add_control_pre_match_rules(config.route.rules, 'main-out');
	if (!groups_need_sniff) {
		for (let group in domain_groups) {
			const match = tun_match(group_match(group));
			if (group.node === '_reject') push(config.route.rules, { ...match, action: 'reject' });
			else if (group.node === '_direct') push_bypass(config.route.rules, match);
			else push_route(config.route.rules, match, group_outbound(group));
		}
		if (length(direct_domain_list))
			push_bypass(config.route.rules, tun_match({ rule_set: 'direct-domain' }));
		if (length(proxy_domain_list))
			push_route(config.route.rules, tun_match({ rule_set: 'proxy-domain' }), 'main-out');
		if (routing_mode === 'bypass_mainland_china' && force_proxy_rules) {
			push_bypass(config.route.rules, tun_match({ rule_set: 'geosite-cn' }));
			push_bypass(config.route.rules, tun_match({ rule_set: 'geoip-cn' }));
		}
	}

	push(config.route.rules, { action: 'sniff' });
	add_control_rules(config.route.rules, 'main-out');

	for (let group in domain_groups)
		push(config.route.rules, group.node === '_reject' ?
			{ ...group_match(group), action: 'reject' } :
			{ ...group_match(group), action: 'route', outbound: group_outbound(group) });

	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rules, {
			rule_set: 'proxy-domain',
			action: 'route',
			outbound: 'main-out'
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.route.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			outbound: 'direct-out'
		});
		push(config.route.rules, {
			rule_set: 'geoip-cn',
			action: 'route',
			outbound: 'direct-out'
		});
	}

	add_tailscale_exit_node_rule(config.route.rules);

	config.route.final = 'main-out';

	/* Rule set */
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: render_domain_rules(direct_domain_list)
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: render_domain_rules(proxy_domain_list)
		});

	if (routing_mode === 'bypass_mainland_china') {
		add_mainland_rule_sets(config.route.rule_set);
	}

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
} else if (!isEmpty(default_outbound)) {
	config.route.default_domain_resolver = {
		server: get_resolver(default_outbound_dns)
	};
	const control_proxy_outbound = default_outbound === 'reject' ? null : get_outbound(default_outbound);
			add_control_pre_match_rules(config.route.rules, control_proxy_outbound);
	push(config.route.rules, { action: 'sniff' });
	add_control_rules(config.route.rules, control_proxy_outbound);

	const bypass_cn_traffic = uci.get(uciconfig, uciroutingsetting, 'bypass_cn_traffic') === '1';
	if (bypass_cn_traffic) {
		push(config.route.rules, {
			rule_set: ['geosite-cn', 'geoip-cn'],
			action: 'route',
			outbound: 'direct-out'
		});
		add_mainland_rule_sets(config.route.rule_set);
	}

	if (domain_strategy)
		push(config.route.rules, {
			action: 'resolve',
			strategy: domain_strategy
		});

	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		const action = cfg.action || 'route';
		const is_route_action = action in ['route', 'route-options'];
		const rule = {
			...renderRouteMatch(cfg, get_ruleset(cfg.rule_set)),
			action: action,
			outbound: (action === 'route') ? get_outbound(cfg.outbound) : null,
			override_address: is_route_action ? cfg.override_address : null,
			override_port: is_route_action ? strToInt(cfg.override_port) : null,
			udp_disable_domain_unmapping: is_route_action ? strToBool(cfg.udp_disable_domain_unmapping) : null,
			udp_connect: is_route_action ? strToBool(cfg.udp_connect) : null,
			udp_timeout: is_route_action ? strToTime(cfg.udp_timeout) : null,
			tls_fragment: is_route_action ? strToBool(cfg.tls_fragment) : null,
			tls_fragment_fallback_delay: is_route_action ? strToTime(cfg.tls_fragment_fallback_delay) : null,
			tls_record_fragment: is_route_action ? strToBool(cfg.tls_record_fragment) : null,
			server: (action === 'resolve') ? get_resolver(cfg.resolve_server) : null,
			strategy: (action === 'resolve') ? cfg.resolve_strategy : null,
			disable_cache: (action === 'resolve') ? strToBool(cfg.resolve_disable_cache) : null,
			disable_optimistic_cache: (action === 'resolve') ?
				strToBool(cfg.resolve_disable_optimistic_cache) : null,
			rewrite_ttl: (action === 'resolve') ? strToInt(cfg.resolve_rewrite_ttl) : null,
			timeout: (action === 'resolve') ? strToTime(cfg.resolve_timeout) : null,
			client_subnet: (action === 'resolve') ? cfg.resolve_client_subnet : null,
			method: (action === 'reject') ? cfg.reject_method : null,
			no_drop: (action === 'reject' && cfg.reject_method !== 'drop') ? strToBool(cfg.reject_no_drop) : null
		};

		if (action === 'route-options' && isEmpty(removeBlankAttrs({
			override_address: rule.override_address,
			override_port: rule.override_port,
			udp_disable_domain_unmapping: rule.udp_disable_domain_unmapping,
			udp_connect: rule.udp_connect,
			udp_timeout: rule.udp_timeout,
			tls_fragment: rule.tls_fragment,
			tls_fragment_fallback_delay: rule.tls_fragment_fallback_delay,
			tls_record_fragment: rule.tls_record_fragment
		})))
			return null;

		push(config.route.rules, rule);
	});
	add_tailscale_exit_node_rule(config.route.rules);

	if (default_outbound === 'reject')
		push(config.route.rules, { action: 'reject' });
	else {
		const final_outbound = get_outbound(default_outbound);
		config.route.final = final_outbound;
	}

	/* Rule set */
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		const ruleset_outbound = (cfg.type === 'remote') ? (get_outbound(cfg.outbound) || 'direct-out') : null;
		push(config.route.rule_set, render_rule_set(cfg, ruleset_outbound));
	});
} else if (tailscale_enabled) {
	config.route.default_domain_resolver = {
		server: 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};
	add_tailscale_exit_node_rule(config.route.rules);
	config.route.final = 'direct-out';
}
if (length(domain_groups)) {
	let referenced = [];
	for (let group in domain_groups) referenced = [...referenced, ...group.rule_set_refs];
	referenced = uniq(referenced);
	for (let id in referenced) {
		const cfg = uci.get_all(uciconfig, id);
		if (!(cfg.type in ['local', 'remote']) ||
		    (cfg.type === 'local' && !cfg.path) || (cfg.type === 'remote' && !cfg.url))
			die('Incomplete diversion rule set: ' + id);
		const outbound = cfg.type === 'remote' ? (cfg.diversion_download_outbound || 'direct-out') : null;
		if (outbound && !(outbound in ['direct-out', 'main-out']))
			die('Invalid diversion rule-set download outbound: ' + id);
		push(config.route.rule_set, render_rule_set(cfg, outbound));
	}
}

/* A private probe selector never carries user connections. */
let smart_probe_port = null;
let smart_probe_tag = null;
if (length(smart_groups)) {
	const reserved = [clash_api_port, dashboard_port, tailscale_api_port];
	for (let inbound in config.inbounds) if (inbound.listen_port) push(reserved, inbound.listen_port);
	const fd = popen('/usr/libexec/sbproxy-random-port ' + join(' ', map(reserved, (p) => int(p))));
	smart_probe_port = fd ? int(fd.read('all')) : null;
	if (fd) fd.close();
	if (!smart_probe_port || smart_probe_port < 1024 || smart_probe_port > 65535)
		die('Unable to allocate smart selection probe port.');
	smart_probe_tag = reserveUniqueLabel(outbound_tags, 'sbproxy-smart-probe-out', 'smart-probe');
	const nodes = [];
	for (let group in smart_groups)
		for (let node in group.nodes) if (index(nodes, node) < 0) push(nodes, node);
	push(config.outbounds, { type: 'selector', tag: smart_probe_tag, outbounds: nodes });
	push(config.inbounds, { type: 'mixed', tag: 'sbproxy-smart-probe-in', listen: '127.0.0.1', listen_port: smart_probe_port });
	unshift(config.route.rules, { inbound: 'sbproxy-smart-probe-in', action: 'route', outbound: smart_probe_tag });
}

/* Routing rules end */

/* Experimental start */
const enable_clash_api = main_node === 'urltest' || length(smart_groups) > 0;
const enable_cache_file = proxy_client_enabled &&
      routing_mode in ['bypass_mainland_china', 'custom'];
if (enable_clash_api || enable_cache_file) {
	config.experimental = {
		clash_api: enable_clash_api ? {
			external_controller: `127.0.0.1:${clash_api_port}`
		} : null,
		cache_file: enable_cache_file ? {
			enabled: true,
			path: SB_DIR + '/cache/cache.db',
			store_dns: strToBool(cache_file_store_dns)
		} : null
	};
}
/* Experimental end */

/* Services */
config.services = [];
if (tailscale_enabled)
	push(config.services, {
		type: 'api',
		tag: 'api-internal',
		listen: '127.0.0.1',
		listen_port: tailscale_api_port
	});
if (dashboard_enabled)
	push(config.services, {
		type: 'api',
		tag: 'api',
		listen: '::',
		listen_port: dashboard_port,
		secret: dashboard_secret,
		dashboard: {
			enabled: true,
			path: dashboard_path
		},
		tls: dashboard_tls_tailscale ? {
			enabled: true,
			server_name: uci.get(uciconfig, ucimain, 'dashboard_tls_name'),
			certificate_provider: {
				type: 'tailscale',
				endpoint: tailscale_endpoint_tag
			}
		} : null
	});
if (derp_server_enabled) {
	const mesh_with = filter(map(
		normalizeList(uci.get(uciconfig, ucitailscale, 'derp_mesh_server')),
		render_derp_mesh_peer
	), (peer) => peer !== null);
	push(config.services, {
		type: 'derp',
		tag: 'sbproxy-derp',
		listen: uci.get(uciconfig, ucitailscale, 'derp_listen') || '::',
		listen_port: strToInt(uci.get(uciconfig, ucitailscale, 'derp_port')) || 8443,
		config_path: uci.get(uciconfig, ucitailscale, 'derp_config_path') ||
			SB_DIR + '/tailscale/derp.json',
		verify_client_endpoint:
			uci.get(uciconfig, ucitailscale, 'derp_verify_tailscale') !== '0' ?
			[ tailscale_endpoint_tag ] : null,
		verify_client_url: normalizeList(
			uci.get(uciconfig, ucitailscale, 'derp_verify_url')
		),
		home: uci.get(uciconfig, ucitailscale, 'derp_home'),
		mesh_with: length(mesh_with) ? mesh_with : null,
		mesh_psk: uci.get(uciconfig, ucitailscale, 'derp_mesh_psk'),
		mesh_psk_file: uci.get(uciconfig, ucitailscale, 'derp_mesh_psk_file'),
		stun: uci.get(uciconfig, ucitailscale, 'derp_stun_enabled') !== '0' ? {
			enabled: true,
			listen: uci.get(uciconfig, ucitailscale, 'derp_stun_listen') || '::',
			listen_port: strToInt(
				uci.get(uciconfig, ucitailscale, 'derp_stun_port')
			) || 3478
		} : null,
		tls: render_derp_tls()
	});
}
if (memory_guard_enabled)
	push(config.services, {
		type: 'oom-killer',
		tag: 'sbproxy-memory-guard',
		memory_limit: memory_guard_limit ? `${memory_guard_limit} MB` : null,
		safety_margin: memory_guard_safety_margin ? `${memory_guard_safety_margin} MB` : null
	});
if (!length(config.services))
	config.services = null;

system('mkdir -p ' + RUN_DIR);
const output_path = getenv('SBPROXY_CLIENT_CONFIG_PATH') || RUN_DIR + '/sing-box-c.json.new';
if (!writefile(output_path, sprintf('%.J\n', removeBlankAttrs(config))))
	exit(1);

if (!writefile(output_path + '.smart.json', sprintf('%.J\n', {
	api_port: clash_api_port, probe_port: smart_probe_port, probe_tag: smart_probe_tag, groups: smart_groups
}))) die('Unable to write smart selection plan.');
