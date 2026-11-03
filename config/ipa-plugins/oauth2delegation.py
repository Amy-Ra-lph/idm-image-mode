#
# IPA OAuth2 Delegation Rule Plugin - Server side (LDAPObject)
#
# Manages on-behalf-of (OBO) delegation authorization rules in LDAP.
# Defines which workload identities can impersonate which users/groups,
# with what scopes, and on which hosts.
#

import ldap.filter

from ipalib import _, errors, output
from ipalib import Str, Bool, Command
from datetime import datetime, timezone
from ipalib.plugable import Registry
from ipapython.dn import DN
from ipaserver.plugins.baseldap import (
    LDAPObject, LDAPCreate, LDAPDelete, LDAPUpdate,
    LDAPSearch, LDAPRetrieve,
)
from ipaserver.plugins.wid_locator import WIDServiceLocator
import os

_MANAGED_PERMS_READY = os.path.exists('/var/lib/ipa-wid/.phase1-complete')

register = Registry()


@register()
class oauth2delegation(LDAPObject):
    """OAuth2 delegation rule (on-behalf-of authorization)."""

    container_dn = 'cn=delegations,cn=oauth2'
    object_name = _('OAuth2 delegation rule')
    object_name_plural = _('OAuth2 delegation rules')
    object_class = ['oauth2DelegationRule']
    default_attributes = [
        'cn', 'oauth2delegatesource', 'oauth2delegatetarget',
        'oauth2delegatescope', 'oauth2delegatehostgroup',
        'oauth2delegateservice', 'oauth2delegatenotafter',
        'oauth2delegaterequireattestation',
        'oauth2enabled', 'description',
    ]
    search_attributes = ['cn', 'oauth2delegatesource', 'description']
    label = _('OAuth2 Delegation Rules')
    label_singular = _('OAuth2 Delegation Rule')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Rule name'),
            primary_key=True,
            pattern='^[a-zA-Z0-9_.-]{1,64}$',
        ),
        Str(
            'oauth2delegatesource',
            cli_name='source',
            label=_('Source workload'),
            doc=_('Workload identity name that may act on behalf of '
                  'others'),
        ),
        Str(
            'oauth2delegatetarget*',
            cli_name='target',
            label=_('Target user/group'),
            doc=_('User or group name that may be impersonated '
                  '(can specify multiple)'),
        ),
        Str(
            'oauth2delegatescope*',
            cli_name='scope',
            label=_('Permitted scope'),
            doc=_('OAuth2 scopes permitted during delegation '
                  '(can specify multiple)'),
        ),
        Str(
            'oauth2delegatehostgroup*',
            cli_name='hostgroup',
            label=_('Target hostgroup'),
            doc=_('IPA hostgroup name restricting where delegation applies '
                  '(can specify multiple)'),
        ),
        Str(
            'oauth2delegateservice*',
            cli_name='service',
            label=_('Permitted service'),
            doc=_('Kerberos service principal the agent may access via '
                  'S4U bridge (e.g., nfs/server.example.com). '
                  'Can specify multiple.'),
        ),
        Str(
            'oauth2delegatenotafter?',
            cli_name='not_after',
            label=_('Expires'),
            doc=_('Rule expiry time in LDAP GeneralizedTime format '
                  '(YYYYMMDDHHmmssZ)'),
        ),
        Bool(
            'oauth2delegaterequireattestation?',
            cli_name='require_attestation',
            label=_('Require attestation'),
            doc=_('Require Keylime/Trustee attestation before granting '
                  'delegation (default: FALSE)'),
            default=False,
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('Enabled'),
            doc=_('Whether this delegation rule is enabled'),
            default=True,
        ),
        Str(
            'description?',
            cli_name='desc',
            label=_('Description'),
        ),
    )

    permission_filter_objectclasses = ['oauth2DelegationRule']
    managed_permissions = {
        'System: Read OAuth2 Delegation Rules': {
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2delegatesource', 'oauth2delegatetarget',
                'oauth2delegatescope', 'oauth2delegatehostgroup',
                'oauth2delegateservice', 'oauth2delegatenotafter',
                'oauth2delegaterequireattestation',
                'oauth2enabled', 'description', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Add OAuth2 Delegation Rules': {
            'ipapermright': {'add'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Delete OAuth2 Delegation Rules': {
            'ipapermright': {'delete'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Modify OAuth2 Delegation Rules': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'oauth2delegatesource', 'oauth2delegatetarget',
                'oauth2delegatescope', 'oauth2delegatehostgroup',
                'oauth2delegateservice', 'oauth2delegatenotafter',
                'oauth2delegaterequireattestation',
                'oauth2enabled', 'description',
            },
            'default_privileges': {'OAuth2 Administrators'},
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2delegation_add(LDAPCreate):
    __doc__ = _('Add a new delegation rule.')
    msg_summary = _('Added delegation rule "%(value)s"')


@register()
class oauth2delegation_del(LDAPDelete):
    __doc__ = _('Delete a delegation rule.')
    msg_summary = _('Deleted delegation rule "%(value)s"')


@register()
class oauth2delegation_mod(LDAPUpdate):
    __doc__ = _('Modify a delegation rule.')
    msg_summary = _('Modified delegation rule "%(value)s"')


@register()
class oauth2delegation_find(LDAPSearch):
    __doc__ = _('Search for delegation rules.')
    msg_summary = _('%(count)d delegation rule(s) matched')


@register()
class oauth2delegation_show(LDAPRetrieve):
    __doc__ = _('Display information about a delegation rule.')


@register()
class oauth2delegation_check(Command):
    __doc__ = _('Check whether a workload may act on behalf of a user.')

    takes_args = (
        Str(
            'workload',
            label=_('Workload name'),
            doc=_('Name of the workload identity requesting delegation'),
        ),
        Str(
            'target_user',
            label=_('Target user'),
            doc=_('User the workload wants to impersonate'),
        ),
    )

    takes_options = (
        Str(
            'scope*',
            label=_('Requested scope'),
            doc=_('OAuth2 scope being requested (can specify multiple)'),
        ),
        Str(
            'on_host?',
            label=_('On host'),
            doc=_('Hostname where delegation would occur'),
        ),
        Str(
            'service?',
            label=_('Target service'),
            doc=_('Kerberos service principal the agent wants to access '
                  '(e.g., nfs/server.example.com)'),
        ),
    )

    has_output = (
        output.Output('summary', type=str),
        output.Output('result', type=dict),
    )

    def execute(self, workload, target_user, **options):
        # DESIGN: 3-way policy check: (1) workload must exist and be enabled,
        # (2) a delegation rule must match source+target+scopes, and
        # (3) host/service confinement must pass if specified. All three
        # must succeed — first-match-wins across rules.

        # Step 1: Verify workload identity exists and is enabled
        try:
            wl = self.api.Command.oauth2workload_show(workload)['result']
        except errors.NotFound:
            return dict(
                summary=u'DENIED: workload identity "%s" not found' % workload,
                result=dict(allowed=False, reason=u'workload_not_found'),
            )

        wl_enabled = wl.get('oauth2enabled', [True])
        if isinstance(wl_enabled, (list, tuple)):
            wl_enabled = wl_enabled[0] if wl_enabled else True
        if wl_enabled is False or str(wl_enabled).upper() == 'FALSE':
            return dict(
                summary=u'DENIED: workload "%s" is disabled' % workload,
                result=dict(allowed=False, reason=u'workload_disabled'),
            )

        # Step 2: Search for delegation rules matching this workload
        ldap_backend = self.api.Backend.ldap2
        base_dn = DN(
            ('cn', 'delegations'), ('cn', 'oauth2'),
            self.api.env.basedn,
        )
        # DESIGN: Uses CN string names (not DNs) for source/target references.
        # DN references would break when entries move or get renamed, and
        # the IPA CLI would need DN resolution for every add/check command.
        filt = (
            '(&(objectClass=oauth2DelegationRule)'
            '(oauth2delegatesource=%s))'
            % ldap.filter.escape_filter_chars(workload)
        )

        try:
            entries = ldap_backend.get_entries(
                base_dn, ldap_backend.SCOPE_ONELEVEL, filt)
        except errors.EmptyResult:
            entries = []
        except errors.NotFound:
            entries = []

        if not entries:
            return dict(
                summary=u'DENIED: no delegation rules for workload "%s"'
                        % workload,
                result=dict(allowed=False, reason=u'no_delegation_rules'),
            )

        # Step 3: Evaluate each rule against the request
        requested_scopes = set(options.get('scope') or [])
        on_host = options.get('on_host')

        for entry in entries:
            # Skip disabled rules
            rule_enabled = entry.single_value.get('oauth2enabled', True)
            if rule_enabled is False or str(rule_enabled).upper() == 'FALSE':
                continue

            # Skip expired rules
            not_after = entry.single_value.get('oauth2delegatenotafter')
            if not_after:
                try:
                    expiry = datetime.strptime(
                        str(not_after), '%Y%m%d%H%M%SZ'
                    ).replace(tzinfo=timezone.utc)
                    if datetime.now(timezone.utc) > expiry:
                        continue
                except (ValueError, TypeError):
                    pass  # malformed date — skip check, don't block

            # Check target user is in the rule's target list.
            # Targets can be user names or group names — resolve group
            # membership if direct name match fails.
            # DESIGN: Two-phase group resolution:
            #   Phase 1: IPA API (group_show) — works for IPA-native groups
            #   Phase 2: NSS/SSSD (os.getgrouplist) — handles AD trust users
            #            whose membership is resolved by SSSD, not stored
            #            in IPA LDAP
            targets = [str(t) for t in entry.get('oauth2delegatetarget', [])]
            if target_user not in targets:
                # Phase 1: Check via IPA API (direct + indirect members)
                target_matched = False
                for target_name in targets:
                    try:
                        self.api.Command.group_show(target_name)
                    except errors.NotFound:
                        continue  # not a group, skip
                    # It's a group — check membership
                    try:
                        members = self.api.Command.group_show(
                            target_name, all=True
                        )['result']
                        member_users = [
                            str(u) for u in
                            members.get('member_user', [])
                        ]
                        if target_user in member_users:
                            target_matched = True
                            break
                        memberof_indirect = [
                            str(u) for u in
                            members.get('memberindirect_user', [])
                        ]
                        if target_user in memberof_indirect:
                            target_matched = True
                            break
                    except Exception:
                        continue

                # Phase 2: NSS fallback for AD trust users
                if not target_matched:
                    try:
                        import pwd
                        import grp
                        import os
                        pw = pwd.getpwnam(target_user)
                        gids = os.getgrouplist(target_user, pw.pw_gid)
                        user_groups = set()
                        for gid in gids:
                            try:
                                user_groups.add(grp.getgrgid(gid).gr_name)
                            except KeyError:
                                pass
                        if user_groups.intersection(targets):
                            target_matched = True
                    except KeyError:
                        pass  # user not resolvable via NSS

                if not target_matched:
                    continue

            # DESIGN: Scope check uses subset semantics — ALL requested scopes
            # must be in the rule's permitted set. This is intentionally strict:
            # partial grants would violate the principle of least surprise.
            permitted = set(
                str(s) for s in entry.get('oauth2delegatescope', []))
            if requested_scopes and not requested_scopes.issubset(permitted):
                continue

            # DESIGN: Host confinement is optional — rules without hostgroups
            # apply everywhere. When specified, the host must be a direct
            # member of at least one listed hostgroup (no nested resolution).
            if on_host:
                hostgroups = [
                    str(h)
                    for h in entry.get('oauth2delegatehostgroup', [])
                ]
                if hostgroups:
                    host_ok = False
                    for hg in hostgroups:
                        try:
                            hg_res = self.api.Command.hostgroup_show(hg)
                            members = [
                                str(m) for m in
                                hg_res.get('result', {}).get(
                                    'member_host', [])
                            ]
                            if on_host in members:
                                host_ok = True
                                break
                        except Exception:
                            continue
                    if not host_ok:
                        continue

            # DESIGN: Service confinement is only enforced when the RULE has
            # constraints. Rules without oauth2DelegateService allow any
            # service (backward compat). If a rule HAS constraints but the
            # caller omits --service, the check still passes here — the
            # /kerberos endpoint enforces target_service separately.
            requested_service = options.get('service')
            permitted_services = set(
                str(s) for s in entry.get('oauth2delegateservice', []))
            if requested_service and permitted_services:
                if requested_service not in permitted_services:
                    continue

            # All checks passed — delegation is authorized
            rule_name = str(entry.single_value['cn'])

            effective_scopes = permitted

            # Vendor scope ceiling: if workload has a vendor, intersect
            # the delegation scopes with the vendor's allowed scopes.
            # effective = vendor_scopes ∩ delegation_scopes
            vendor_dn_vals = wl.get('oauth2workloadvendor', [])
            if vendor_dn_vals:
                vendor_dn_str = (
                    str(vendor_dn_vals[0])
                    if isinstance(vendor_dn_vals, (list, tuple))
                    else str(vendor_dn_vals)
                )
                if vendor_dn_str:
                    try:
                        vendor_entry = ldap_backend.get_entry(
                            DN(vendor_dn_str), [
                                'oauth2vendorscope', 'oauth2enabled',
                                'oauth2vendornotafter',
                            ])
                        # Check vendor enabled
                        v_enabled = vendor_entry.single_value.get(
                            'oauth2enabled', True)
                        if (v_enabled is False
                                or str(v_enabled).upper() == 'FALSE'):
                            continue  # vendor disabled, skip this rule

                        # Check vendor expiry
                        v_expiry = vendor_entry.single_value.get(
                            'oauth2vendornotafter')
                        if v_expiry:
                            try:
                                exp_dt = datetime.strptime(
                                    str(v_expiry), '%Y%m%d%H%M%SZ'
                                ).replace(tzinfo=timezone.utc)
                                if datetime.now(timezone.utc) > exp_dt:
                                    continue  # vendor expired
                            except (ValueError, TypeError):
                                pass

                        # Intersect scopes
                        vendor_scopes = set(
                            str(s) for s in vendor_entry.get(
                                'oauth2vendorscope', []))
                        if vendor_scopes:
                            effective_scopes = permitted & vendor_scopes
                    except errors.NotFound:
                        pass  # vendor entry gone — allow delegation scopes

            result = dict(
                allowed=True,
                reason=u'authorized',
                rule=rule_name,
                permitted_scopes=sorted(effective_scopes),
            )
            if permitted_services:
                result['permitted_services'] = sorted(permitted_services)

            wl_type = wl.get('oauth2workloadtype', [])
            if wl_type:
                result['workload_type'] = (
                    str(wl_type[0])
                    if isinstance(wl_type, (list, tuple))
                    else str(wl_type)
                )

            spiffe = wl.get('oauth2spiffeid', [])
            if spiffe:
                result['spiffe_id'] = (
                    str(spiffe[0])
                    if isinstance(spiffe, (list, tuple))
                    else str(spiffe)
                )

            # Add WID service status for graceful degradation context
            locator = WIDServiceLocator()
            result['wid_services'] = {
                'obo': locator.status_message('obo'),
                'ahdapa': locator.status_message('ahdapa'),
            }

            return dict(
                summary=u'ALLOWED: rule "%s" authorizes %s to act as %s'
                        % (rule_name, workload, target_user),
                result=result,
            )

        # No rule matched all criteria
        return dict(
            summary=u'DENIED: no matching rule for %s acting as %s'
                    % (workload, target_user),
            result=dict(allowed=False, reason=u'no_matching_rule'),
        )
