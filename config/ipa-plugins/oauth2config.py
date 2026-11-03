#
# IPA OAuth2 Config Plugin - Server side (LDAPObject)
#
# Global OAuth2 subsystem configuration (singleton).
#

from ipalib import _
from ipalib import Str, Bool, Int
from ipalib.plugable import Registry
from ipaserver.plugins.baseldap import (
    LDAPObject, LDAPUpdate, LDAPRetrieve,
)
import os

_MANAGED_PERMS_READY = os.path.exists('/var/lib/ipa-wid/.phase1-complete')

register = Registry()


@register()
class oauth2config(LDAPObject):
    """Global OAuth2 subsystem configuration."""

    container_dn = 'cn=oauth2'
    object_name = _('OAuth2 configuration')
    object_name_plural = _('OAuth2 configuration')
    object_class = ['oauth2Config']
    default_attributes = [
        'cn', 'oauth2enabled', 'oauth2tokenlifetime',
        'oauth2refreshtokenlifetime', 'description',
    ]
    label = _('OAuth2 Configuration')
    label_singular = _('OAuth2 Configuration')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Name'),
            primary_key=True,
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('OAuth2 enabled'),
            doc=_('Enable or disable the OAuth2 subsystem globally'),
        ),
        Int(
            'oauth2tokenlifetime?',
            cli_name='token_lifetime',
            label=_('Default token lifetime'),
            doc=_('Default access token lifetime in seconds'),
            minvalue=60,
            maxvalue=86400,
        ),
        Int(
            'oauth2refreshtokenlifetime?',
            cli_name='refresh_token_lifetime',
            label=_('Default refresh token lifetime'),
            doc=_('Default refresh token lifetime in seconds'),
            minvalue=60,
            maxvalue=604800,
        ),
        Str(
            'description?',
            cli_name='desc',
            label=_('Description'),
        ),
    )

    permission_filter_objectclasses = ['oauth2Config']
    managed_permissions = {
        'System: Read OAuth2 Config': {
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2enabled', 'oauth2tokenlifetime',
                'oauth2refreshtokenlifetime', 'description', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Modify OAuth2 Config': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'oauth2enabled', 'oauth2tokenlifetime',
                'oauth2refreshtokenlifetime', 'description',
            },
            'default_privileges': {'OAuth2 Administrators'},
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2config_mod(LDAPUpdate):
    __doc__ = _('Modify OAuth2 subsystem configuration.')
    msg_summary = _('Modified OAuth2 configuration')


@register()
class oauth2config_show(LDAPRetrieve):
    __doc__ = _('Display OAuth2 subsystem configuration.')
