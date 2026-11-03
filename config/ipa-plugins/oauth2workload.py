#
# IPA OAuth2 Workload Identity Plugin - Server side (LDAPObject)
#
# Manages non-human identity (NHI) registrations in LDAP.
# Links workload identities to SPIFFE IDs, IPA users, and OAuth2 clients.
#

import json
import time
import ldap.filter as ldap_filter

from ipalib import _, errors, output
from ipalib import Str, StrEnum, Bool, Int, Command
from ipalib.plugable import Registry
from ipapython.dn import DN
from ipaserver.plugins.baseldap import (
    LDAPObject, LDAPCreate, LDAPDelete, LDAPUpdate,
    LDAPSearch, LDAPRetrieve,
)
import os

_MANAGED_PERMS_READY = os.path.exists('/var/lib/ipa-wid/.phase1-complete')

register = Registry()


@register()
class oauth2workload(LDAPObject):
    """OAuth2 workload identity (non-human identity)."""

    # DESIGN: Workload identities live in cn=oauth2, NOT under cn=services,
    # because IPA services are 1:1 with host principals (SVC/host@REALM).
    # Workloads need extra attributes (SPIFFE ID, type, delegation links)
    # that don't map to the ipaService objectclass.
    container_dn = 'cn=workloads,cn=oauth2'
    object_name = _('OAuth2 workload identity')
    object_name_plural = _('OAuth2 workload identities')
    object_class = ['oauth2WorkloadIdentity']
    default_attributes = [
        'cn', 'oauth2workloadtype', 'oauth2spiffeid',
        'oauth2workloadowner', 'oauth2workloadclient',
        'oauth2workloadserviceprincipal', 'oauth2workloadvendor',
        'oauth2enabled', 'oauth2maxtokenlifetime',
        'oauth2workloadskill', 'oauth2workloadcardttl', 'description',
    ]
    search_attributes = [
        'cn', 'oauth2spiffeid', 'oauth2workloadtype',
        'oauth2workloadskill', 'description',
    ]
    label = _('OAuth2 Workload Identities')
    label_singular = _('OAuth2 Workload Identity')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Workload name'),
            primary_key=True,
            pattern='^[a-zA-Z0-9_.-]{1,64}$',
        ),
        StrEnum(
            'oauth2workloadtype',
            cli_name='type',
            label=_('Workload type'),
            doc=_('Type of non-human identity: agent, service, or workload'),
            values=(u'agent', u'service', u'workload'),
        ),
        # DESIGN: SPIFFE ID format is spiffe://<trust-domain>/<path> per the
        # SPIFFE spec. Stored as-is — no validation here because the trust
        # domain may differ from the IPA domain (federated SPIRE deployments).
        Str(
            'oauth2spiffeid?',
            cli_name='spiffe_id',
            label=_('SPIFFE ID'),
            doc=_('SPIFFE ID URI (e.g. spiffe://example.com/workload/name)'),
        ),
        Str(
            'oauth2workloadowner?',
            cli_name='owner',
            label=_('Owner'),
            doc=_('IPA username of the system account that owns this '
                  'workload'),
        ),
        Str(
            'oauth2workloadclient?',
            cli_name='client',
            label=_('OAuth2 client'),
            doc=_('Name of the associated OAuth2 client registration'),
        ),
        Str(
            'oauth2workloadserviceprincipal?',
            cli_name='service_principal',
            label=_('Service principal'),
            doc=_('IPA service principal for this workload '
                  '(e.g., agent/mcp-postgres.example.com). '
                  'Auto-created if it does not exist.'),
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('Enabled'),
            doc=_('Whether this workload identity is enabled'),
            default=True,
        ),
        Int(
            'oauth2maxtokenlifetime?',
            cli_name='max_token_lifetime',
            label=_('Max token lifetime'),
            doc=_('Maximum token lifetime in seconds (overrides client '
                  'default)'),
            minvalue=60,
            maxvalue=86400,
        ),
        Str(
            'oauth2workloadvendor?',
            cli_name='vendor',
            label=_('Vendor'),
            doc=_('Name of the trusted vendor that supplied this workload. '
                  'Stored as a DN reference to the vendor entry.'),
        ),
        Str(
            'oauth2workloadskill*',
            cli_name='skill',
            label=_('Skill'),
            doc=_('Agent skill tag for capability-based discovery '
                  '(e.g. database-query, schema-inspection)'),
        ),
        Int(
            'oauth2workloadcardttl?',
            cli_name='card_ttl',
            label=_('Card TTL'),
            doc=_('Agent card validity in seconds (default 3600)'),
            minvalue=60,
            maxvalue=86400,
            default=3600,
        ),
        Str(
            'description?',
            cli_name='desc',
            label=_('Description'),
        ),
    )

    permission_filter_objectclasses = ['oauth2WorkloadIdentity']
    managed_permissions = {
        'System: Read OAuth2 Workload Identities': {
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2workloadtype', 'oauth2spiffeid',
                'oauth2workloadowner', 'oauth2workloadclient',
                'oauth2workloadserviceprincipal', 'oauth2workloadvendor',
                'oauth2enabled', 'oauth2maxtokenlifetime',
                'oauth2workloadskill', 'oauth2workloadcardttl',
                'description', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Add OAuth2 Workload Identities': {
            'ipapermright': {'add'},
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
        'System: Delete OAuth2 Workload Identities': {
            'ipapermright': {'delete'},
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
        'System: Modify OAuth2 Workload Identities': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'oauth2workloadtype', 'oauth2spiffeid',
                'oauth2workloadowner', 'oauth2workloadclient',
                'oauth2workloadserviceprincipal', 'oauth2workloadvendor',
                'oauth2enabled', 'oauth2maxtokenlifetime',
                'oauth2workloadskill', 'oauth2workloadcardttl',
                'description',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2workload_add(LDAPCreate):
    __doc__ = _('Register a new workload identity.')
    msg_summary = _('Registered workload identity "%(value)s"')

    def pre_callback(self, ldap, dn, entry_attrs, attrs_list,
                     *keys, **options):
        # Convert vendor name to DN reference
        vendor = entry_attrs.get('oauth2workloadvendor')
        if vendor:
            vendor_name = str(vendor) if not isinstance(vendor, str) else vendor
            vendor_dn = DN(
                ('cn', vendor_name), ('cn', 'vendors'),
                ('cn', 'oauth2'), self.api.env.basedn)
            try:
                ldap.get_entry(vendor_dn, ['cn'])
            except errors.NotFound:
                raise errors.NotFound(
                    reason=_('Trusted vendor "%(vendor)s" not found') %
                    {'vendor': vendor_name})
            entry_attrs['oauth2workloadvendor'] = str(vendor_dn)
        return dn

    def post_callback(self, ldap, dn, entry_attrs, *keys, **options):
        # DESIGN: Auto-create the IPA service principal so the S4U2Self bridge
        # can use it immediately. Without this, admins would need a separate
        # `ipa service-add` step, and the workload would fail on first use.
        # The host portion must be an enrolled IPA host or service_add fails.
        svc = entry_attrs.get('oauth2workloadserviceprincipal')
        if svc:
            svc_name = str(svc[0]) if isinstance(svc, (list, tuple)) else str(svc)
            try:
                self.api.Command.service_add(svc_name)
            except errors.DuplicateEntry:
                pass  # already exists, just link it
        return dn


@register()
class oauth2workload_del(LDAPDelete):
    __doc__ = _('Delete a workload identity.')
    msg_summary = _('Deleted workload identity "%(value)s"')


@register()
class oauth2workload_mod(LDAPUpdate):
    __doc__ = _('Modify a workload identity.')
    msg_summary = _('Modified workload identity "%(value)s"')

    def pre_callback(self, ldap, dn, entry_attrs, attrs_list,
                     *keys, **options):
        vendor = entry_attrs.get('oauth2workloadvendor')
        if vendor:
            vendor_name = str(vendor) if not isinstance(vendor, str) else vendor
            vendor_dn = DN(
                ('cn', vendor_name), ('cn', 'vendors'),
                ('cn', 'oauth2'), self.api.env.basedn)
            try:
                ldap.get_entry(vendor_dn, ['cn'])
            except errors.NotFound:
                raise errors.NotFound(
                    reason=_('Trusted vendor "%(vendor)s" not found') %
                    {'vendor': vendor_name})
            entry_attrs['oauth2workloadvendor'] = str(vendor_dn)
        return dn


@register()
class oauth2workload_find(LDAPSearch):
    __doc__ = _('Search for workload identities.')
    msg_summary = _('%(count)d workload identity(ies) matched')

    takes_options = LDAPSearch.takes_options + (
        Str(
            'find_skill?',
            cli_name='find_skill',
            label=_('Find by skill'),
            doc=_('Filter by agent skill tag'),
        ),
        Str(
            'find_capability?',
            cli_name='find_capability',
            label=_('Find by capability'),
            doc=_('Filter by OAuth2 scope capability (searches delegation '
                  'rules for workloads with this scope)'),
        ),
    )

    def pre_callback(self, ldap, filters, attrs_list, base_dn,
                     scope, *args, **options):
        skill = options.pop('find_skill', None)
        capability = options.pop('find_capability', None)

        if skill:
            skill_filter = (
                '(oauth2workloadskill=%s)'
                % ldap_filter.escape_filter_chars(skill)
            )
            filters = ldap.combine_filters(
                [filters, skill_filter], ldap.MATCH_ALL)

        if capability:
            # Find workloads that have delegation rules granting this scope.
            # Search delegation rules, collect source workload names, then
            # add an OR filter matching those CNs.
            deleg_base = DN(
                ('cn', 'delegations'), ('cn', 'oauth2'),
                self.api.env.basedn,
            )
            scope_filter = (
                '(&(objectClass=oauth2DelegationRule)'
                '(oauth2delegatescope=%s))'
                % ldap_filter.escape_filter_chars(capability)
            )
            try:
                deleg_entries = ldap.get_entries(
                    deleg_base, ldap.SCOPE_ONELEVEL, scope_filter,
                    ['oauth2delegatesource'])
            except (errors.EmptyResult, errors.NotFound):
                deleg_entries = []

            sources = set()
            for entry in deleg_entries:
                src = entry.single_value.get('oauth2delegatesource')
                if src:
                    sources.add(str(src))

            if sources:
                cn_filters = [
                    '(cn=%s)' % ldap_filter.escape_filter_chars(s)
                    for s in sources
                ]
                cap_filter = ldap.combine_filters(
                    cn_filters, ldap.MATCH_ANY)
                filters = ldap.combine_filters(
                    [filters, cap_filter], ldap.MATCH_ALL)
            else:
                # No workloads have this capability — force empty result
                filters = '(&(cn=__no_match__)(objectClass=oauth2WorkloadIdentity))'

        return filters, base_dn, scope


@register()
class oauth2workload_show(LDAPRetrieve):
    __doc__ = _('Display information about a workload identity.')


@register()
class oauth2workload_show_card(Command):
    __doc__ = _('Display the agent card for a workload identity.')

    takes_args = (
        Str(
            'cn',
            cli_name='name',
            label=_('Workload name'),
        ),
    )

    has_output = (
        output.Output('summary', type=str),
        output.Output('result', type=dict),
    )

    def execute(self, cn, **options):
        # Step 1: Fetch workload entry
        try:
            wl_result = self.api.Command.oauth2workload_show(cn)['result']
        except errors.NotFound:
            raise errors.NotFound(
                reason=_('Workload identity "%(name)s" not found')
                % {'name': cn})

        # Helper to extract single value from IPA result
        def sv(key, default=None):
            val = wl_result.get(key, [default])
            if isinstance(val, (list, tuple)):
                return str(val[0]) if val else default
            return str(val) if val is not None else default

        def mv(key):
            val = wl_result.get(key, [])
            if isinstance(val, (list, tuple)):
                return [str(v) for v in val]
            return [str(val)] if val else []

        # Step 2: Aggregate delegation rules for this workload
        ldap_backend = self.api.Backend.ldap2
        deleg_base = DN(
            ('cn', 'delegations'), ('cn', 'oauth2'),
            self.api.env.basedn,
        )
        filt = (
            '(&(objectClass=oauth2DelegationRule)'
            '(oauth2delegatesource=%s)'
            '(!(oauth2enabled=FALSE)))'
            % ldap_filter.escape_filter_chars(cn)
        )

        try:
            deleg_entries = ldap_backend.get_entries(
                deleg_base, ldap_backend.SCOPE_ONELEVEL, filt,
                ['oauth2delegatescope', 'oauth2delegatehostgroup',
                 'oauth2delegateservice'])
        except (errors.EmptyResult, errors.NotFound):
            deleg_entries = []

        all_scopes = set()
        all_hostgroups = set()
        all_services = set()
        for entry in deleg_entries:
            for s in entry.get('oauth2delegatescope', []):
                all_scopes.add(str(s))
            for h in entry.get('oauth2delegatehostgroup', []):
                all_hostgroups.add(str(h))
            for s in entry.get('oauth2delegateservice', []):
                all_services.add(str(s))

        # Step 3: Assemble the card
        card_ttl = sv('oauth2workloadcardttl', '3600')
        try:
            ttl_secs = int(card_ttl)
        except (ValueError, TypeError):
            ttl_secs = 3600

        now = int(time.time())
        card = {
            'name': sv('cn'),
            'version': '1.0',
            'skills': mv('oauth2workloadskill'),
            'capabilities': sorted(all_scopes),
            'identity': {
                'ipa_principal': sv('cn'),
                'service_principal': sv('oauth2workloadserviceprincipal'),
                'spiffe_id': sv('oauth2spiffeid'),
                'client_id': sv('oauth2workloadclient'),
            },
            'delegation': {
                'max_scopes': sorted(all_scopes),
                'hostgroups': sorted(all_hostgroups),
                'services': sorted(all_services),
            },
            'iss': 'https://%s' % self.api.env.host,
            'iat': now,
            'exp': now + ttl_secs,
        }

        # Remove None values from identity block
        card['identity'] = {
            k: v for k, v in card['identity'].items() if v is not None
        }

        description = sv('description')
        if description:
            card['description'] = description

        return dict(
            summary=u'Agent card for "%s"' % cn,
            result=card,
        )
