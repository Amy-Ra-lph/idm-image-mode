#
# IPA OAuth2 Trusted Vendor Plugin - Server side (LDAPObject)
#
# Manages trusted third-party vendor registrations in LDAP.
# Each vendor entry stores a code-signing CA certificate, scope ceiling,
# and lifecycle controls (expiry, kill switch).
#

from ipalib import _, errors
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
class oauth2vendor(LDAPObject):
    """OAuth2 trusted vendor."""

    container_dn = 'cn=vendors,cn=oauth2'
    object_name = _('OAuth2 trusted vendor')
    object_name_plural = _('OAuth2 trusted vendors')
    object_class = ['oauth2TrustedVendor']
    default_attributes = [
        'cn', 'oauth2vendorcacert', 'oauth2vendorscope',
        'oauth2vendornotafter', 'oauth2vendorcontact',
        'oauth2vendorrekorurl', 'oauth2enabled', 'description',
    ]
    search_attributes = ['cn', 'oauth2vendorcontact', 'description']
    label = _('OAuth2 Trusted Vendors')
    label_singular = _('OAuth2 Trusted Vendor')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Vendor name'),
            primary_key=True,
            pattern='^[a-zA-Z0-9_.-]{1,64}$',
        ),
        # DESIGN: PEM-encoded CA cert passed as a string. The CLI accepts
        # a file path via --ca-cert=@/path/to/cert.pem (IPA's @ file syntax).
        # Stored as Octet String in LDAP.
        Str(
            'oauth2vendorcacert',
            cli_name='ca_cert',
            label=_('CA certificate'),
            doc=_('PEM-encoded vendor code-signing CA certificate '
                  '(use @/path/to/cert.pem to read from file)'),
        ),
        Str(
            'oauth2vendorscope*',
            cli_name='scope',
            label=_('Allowed scopes'),
            doc=_('Maximum OAuth2 scopes permitted for workloads from '
                  'this vendor (scope ceiling)'),
        ),
        Str(
            'oauth2vendornotafter?',
            cli_name='expires',
            label=_('Expires'),
            doc=_('Vendor trust expiry in GeneralizedTime format '
                  '(e.g. 20261231235959Z)'),
        ),
        Str(
            'oauth2vendorcontact?',
            cli_name='contact',
            label=_('Contact email'),
            doc=_('Vendor contact email for trust lifecycle notifications'),
        ),
        Str(
            'oauth2vendorrekorurl?',
            cli_name='rekor_url',
            label=_('Rekor URL'),
            doc=_('Vendor Rekor transparency log URL for signature '
                  'verification'),
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('Enabled'),
            doc=_('Whether this vendor trust is enabled (kill switch)'),
            default=True,
        ),
        Str(
            'description?',
            cli_name='desc',
            label=_('Description'),
        ),
    )

    permission_filter_objectclasses = ['oauth2TrustedVendor']
    managed_permissions = {
        'System: Read OAuth2 Trusted Vendors': {
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2vendorcacert', 'oauth2vendorscope',
                'oauth2vendornotafter', 'oauth2vendorcontact',
                'oauth2vendorrekorurl', 'oauth2enabled',
                'description', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Add OAuth2 Trusted Vendors': {
            'ipapermright': {'add'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Delete OAuth2 Trusted Vendors': {
            'ipapermright': {'delete'},
            'default_privileges': {'OAuth2 Administrators'},
        },
        'System: Modify OAuth2 Trusted Vendors': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'oauth2vendorcacert', 'oauth2vendorscope',
                'oauth2vendornotafter', 'oauth2vendorcontact',
                'oauth2vendorrekorurl', 'oauth2enabled',
                'description',
            },
            'default_privileges': {'OAuth2 Administrators'},
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2vendor_add(LDAPCreate):
    __doc__ = _('Register a new trusted vendor.')
    msg_summary = _('Registered trusted vendor "%(value)s"')


@register()
class oauth2vendor_del(LDAPDelete):
    __doc__ = _('Delete a trusted vendor.')
    msg_summary = _('Deleted trusted vendor "%(value)s"')


@register()
class oauth2vendor_mod(LDAPUpdate):
    __doc__ = _('Modify a trusted vendor.')
    msg_summary = _('Modified trusted vendor "%(value)s"')


@register()
class oauth2vendor_find(LDAPSearch):
    __doc__ = _('Search for trusted vendors.')
    msg_summary = _('%(count)d trusted vendor(s) matched')


@register()
class oauth2vendor_show(LDAPRetrieve):
    __doc__ = _('Display information about a trusted vendor.')
