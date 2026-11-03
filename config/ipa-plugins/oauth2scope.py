#
# IPA OAuth2 Scope Plugin - Server side (LDAPObject)
#
# Manages OAuth2 scope definitions in LDAP.
#

from ipalib import _
from ipalib import Str, Bool
from ipalib.plugable import Registry
from ipaserver.plugins.baseldap import (
    LDAPObject, LDAPCreate, LDAPDelete, LDAPUpdate,
    LDAPSearch, LDAPRetrieve,
)
import os

_MANAGED_PERMS_READY = os.path.exists('/var/lib/ipa-wid/.phase1-complete')

register = Registry()


@register()
class oauth2scope(LDAPObject):
    """OAuth2 scope definition."""

    container_dn = 'cn=scopes,cn=oauth2'
    object_name = _('OAuth2 scope')
    object_name_plural = _('OAuth2 scopes')
    object_class = ['oauth2ScopeDefinition']
    default_attributes = [
        'cn', 'oauth2scope', 'oauth2scopedescription', 'oauth2enabled',
    ]
    search_attributes = ['cn', 'oauth2scope', 'oauth2scopedescription']
    label = _('OAuth2 Scopes')
    label_singular = _('OAuth2 Scope')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Scope name'),
            primary_key=True,
            pattern='^[a-zA-Z0-9_.-]{1,64}$',
        ),
        Str(
            'oauth2scope',
            cli_name='scope',
            label=_('Scope value'),
            doc=_('OAuth2 scope string (e.g. openid, profile, email)'),
        ),
        Str(
            'oauth2scopedescription?',
            cli_name='desc',
            label=_('Description'),
            doc=_('Human-readable scope description'),
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('Enabled'),
            default=True,
        ),
    )

    permission_filter_objectclasses = ['oauth2ScopeDefinition']
    managed_permissions = {
        'System: Read OAuth2 Scopes': {
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2scope', 'oauth2scopedescription',
                'oauth2enabled', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Add OAuth2 Scopes': {
            'ipapermright': {'add'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Delete OAuth2 Scopes': {
            'ipapermright': {'delete'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Modify OAuth2 Scopes': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'oauth2scope', 'oauth2scopedescription', 'oauth2enabled',
            },
            'default_privileges': {'OAuth2 Administrators'},
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2scope_add(LDAPCreate):
    __doc__ = _('Add a new OAuth2 scope definition.')
    msg_summary = _('Added OAuth2 scope "%(value)s"')


@register()
class oauth2scope_del(LDAPDelete):
    __doc__ = _('Delete an OAuth2 scope definition.')
    msg_summary = _('Deleted OAuth2 scope "%(value)s"')


@register()
class oauth2scope_mod(LDAPUpdate):
    __doc__ = _('Modify an OAuth2 scope definition.')
    msg_summary = _('Modified OAuth2 scope "%(value)s"')


@register()
class oauth2scope_find(LDAPSearch):
    __doc__ = _('Search for OAuth2 scope definitions.')
    msg_summary = _('%(count)d OAuth2 scope(s) matched')


@register()
class oauth2scope_show(LDAPRetrieve):
    __doc__ = _('Display information about an OAuth2 scope.')
