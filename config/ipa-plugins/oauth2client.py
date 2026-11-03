#
# IPA OAuth2 Client Plugin - Server side (LDAPObject)
#
# Manages OAuth2/OIDC client registrations in LDAP,
# synced to Keycloak via ipa-oauth2d.
#

import hashlib
import os
import re

from ipalib import _
from ipalib import Command, Str, StrEnum, Bool, Int, output
from ipalib.plugable import Registry
from ipaserver.plugins.baseldap import (
    LDAPObject, LDAPCreate, LDAPDelete, LDAPUpdate,
    LDAPSearch, LDAPRetrieve,
)

_MANAGED_PERMS_READY = os.path.exists('/var/lib/ipa-wid/.phase1-complete')

register = Registry()


@register()
class oauth2client(LDAPObject):
    """OAuth2/OIDC client registration."""

    # DESIGN: Separate cn=oauth2 subtree instead of cn=services because OAuth2
    # clients are not IPA services — they have different lifecycles and RBAC.
    container_dn = 'cn=clients,cn=oauth2'
    object_name = _('OAuth2 client')
    object_name_plural = _('OAuth2 clients')
    object_class = ['oauth2Client']
    default_attributes = [
        'cn', 'oauth2clientid', 'oauth2redirecturi',
        'oauth2granttype', 'oauth2scope', 'oauth2clienttype',
        'oauth2tokenlifetime', 'oauth2enabled', 'oauth2clientsecret',
        'oauth2keycloakid', 'description',
    ]
    search_attributes = ['cn', 'oauth2clientid', 'description']
    label = _('OAuth2 Clients')
    label_singular = _('OAuth2 Client')

    takes_params = (
        Str(
            'cn',
            cli_name='name',
            label=_('Client name'),
            primary_key=True,
            pattern='^[a-zA-Z0-9_.-]{1,64}$',
        ),
        Str(
            'oauth2clientid',
            cli_name='client_id',
            label=_('Client ID'),
            doc=_('OAuth2 client identifier'),
        ),
        Str(
            'oauth2redirecturi*',
            cli_name='redirect_uri',
            label=_('Redirect URI'),
            doc=_('Authorized redirect URI (can specify multiple)'),
            pattern=r'^https?://',
            pattern_errmsg='Redirect URI must start with http:// or https://',
        ),
        StrEnum(
            'oauth2granttype*',
            cli_name='grant_type',
            label=_('Grant type'),
            doc=_('OAuth2 grant type (authorization_code, client_credentials, '
                  'implicit, device_code)'),
            values=(u'authorization_code', u'client_credentials',
                    u'implicit', u'device_code', u'password'),
        ),
        Str(
            'oauth2scope*',
            cli_name='scope',
            label=_('Scope'),
            doc=_('Allowed OAuth2 scopes'),
            pattern=r'^[a-zA-Z0-9_.:\-/]+$',
            pattern_errmsg='Scope must contain only alphanumeric characters, '
                           'dots, underscores, colons, hyphens, and slashes',
        ),
        StrEnum(
            'oauth2clienttype?',
            cli_name='client_type',
            label=_('Client type'),
            doc=_('Client type: confidential or public'),
            values=(u'confidential', u'public'),
            default=u'confidential',
        ),
        Int(
            'oauth2tokenlifetime?',
            cli_name='token_lifetime',
            label=_('Token lifetime'),
            doc=_('Access token lifetime in seconds'),
            default=300,
            minvalue=60,
            maxvalue=86400,
        ),
        Bool(
            'oauth2enabled?',
            cli_name='enabled',
            label=_('Enabled'),
            doc=_('Whether this client is enabled'),
            default=True,
        ),
        Str(
            'oauth2clientsecret?',
            cli_name='client_secret',
            label=_('Client secret'),
            doc=_('Hashed client secret (use oauth2client-generate-secret '
                  'to set)'),
            flags={'no_create', 'no_update', 'no_search'},
        ),
        Str(
            'oauth2keycloakid?',
            cli_name='keycloak_id',
            label=_('Keycloak ID'),
            doc=_('Keycloak internal client UUID (managed by sync daemon)'),
            flags={'no_create', 'no_update'},
        ),
        Str(
            'description?',
            cli_name='desc',
            label=_('Description'),
        ),
    )

    permission_filter_objectclasses = ['oauth2Client']
    # DESIGN: managed_permissions auto-create ACIs on ipa-server-upgrade. The
    # privileges (OAuth2 Administrators, etc.) must be created BEFORE upgrade
    # runs, or the auto-assignment silently skips them.
    managed_permissions = {
        'System: Read OAuth2 Clients': {
            # DESIGN: replaces_global_anonymous_aci prevents the default
            # anonymous read ACI from granting access to OAuth2 entries.
            'replaces_global_anonymous_aci': True,
            'ipapermright': {'read', 'search', 'compare'},
            'ipapermdefaultattr': {
                'cn', 'oauth2clientid', 'oauth2redirecturi',
                'oauth2granttype', 'oauth2scope', 'oauth2clienttype',
                'oauth2tokenlifetime', 'oauth2enabled',
                'oauth2keycloakid', 'description', 'objectclass',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
                'OAuth2 Readers',
            },
        },
        'System: Add OAuth2 Clients': {
            'ipapermright': {'add'},
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
        'System: Delete OAuth2 Clients': {
            'ipapermright': {'delete'},
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
        'System: Modify OAuth2 Clients': {
            'ipapermright': {'write'},
            'ipapermdefaultattr': {
                'cn', 'oauth2clientid', 'oauth2redirecturi',
                'oauth2granttype', 'oauth2scope', 'oauth2clienttype',
                'oauth2tokenlifetime', 'oauth2enabled', 'oauth2clientsecret',
                'oauth2keycloakid', 'description',
            },
            'default_privileges': {
                'OAuth2 Administrators',
                'OAuth2 Client Managers',
            },
        },
    } if _MANAGED_PERMS_READY else {}


@register()
class oauth2client_add(LDAPCreate):
    __doc__ = _('Register a new OAuth2 client.')
    msg_summary = _('Registered OAuth2 client "%(value)s"')


@register()
class oauth2client_del(LDAPDelete):
    __doc__ = _('Delete an OAuth2 client registration.')
    msg_summary = _('Deleted OAuth2 client "%(value)s"')


@register()
class oauth2client_mod(LDAPUpdate):
    __doc__ = _('Modify an OAuth2 client.')
    msg_summary = _('Modified OAuth2 client "%(value)s"')


@register()
class oauth2client_find(LDAPSearch):
    __doc__ = _('Search for OAuth2 clients.')
    msg_summary = _('%(count)d OAuth2 client(s) matched')


@register()
class oauth2client_show(LDAPRetrieve):
    __doc__ = _('Display information about an OAuth2 client.')


def _generate_secret():
    """Generate a cryptographically random client secret."""
    return os.urandom(32).hex()


def _hash_secret(plaintext):
    """Hash a client secret with PBKDF2-SHA256 for LDAP storage."""
    # DESIGN: PBKDF2 with 600k iterations (OWASP 2024 recommendation) instead
    # of plain SHA-256 because client secrets are low-entropy compared to
    # passwords — offline brute-force must be computationally expensive.
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac(
        'sha256', plaintext.encode('utf-8'), salt, iterations=600000)
    return '%s$%s' % (salt.hex(), dk.hex())


@register()
class oauth2client_generate_secret(Command):
    __doc__ = _('Generate a new client secret for an OAuth2 client.')

    takes_args = (
        Str(
            'cn',
            cli_name='name',
            label=_('Client name'),
        ),
    )

    has_output = (
        output.summary,
        output.Entry('result'),
        output.Output('value', type=str),
    )

    has_output_params = (
        Str(
            'secret',
            label=_('Client secret'),
        ),
    )

    msg_summary = _('Generated new secret for OAuth2 client "%(value)s"')

    def execute(self, cn, **options):
        ldap = self.api.Backend.ldap2
        dn = self.api.Object.oauth2client.get_dn(cn)

        # Verify the client exists
        try:
            entry = ldap.get_entry(dn, ['cn', 'oauth2clienttype'])
        except Exception:
            raise self.api.Object.oauth2client.handle_not_found(cn)

        # Only confidential clients should have secrets
        client_type = entry.get('oauth2clienttype', ['confidential'])
        if isinstance(client_type, (list, tuple)):
            client_type = client_type[0] if client_type else 'confidential'
        if client_type == 'public':
            from ipalib.errors import ValidationError
            raise ValidationError(
                name='client_type',
                error=_('Public clients cannot have a client secret'),
            )

        # Generate and hash the secret
        plaintext = _generate_secret()
        hashed = _hash_secret(plaintext)

        # Store hashed secret in LDAP
        entry['oauth2clientsecret'] = [hashed]
        ldap.update_entry(entry)

        # DESIGN: LDAP stores only the hash, but Keycloak needs the plaintext.
        # We bridge via a tmpfs file that the sync daemon picks up and wipes.
        # This avoids storing plaintext in LDAP or passing it via IPC.
        secret_dir = '/run/ipa/oauth2-secrets'
        try:
            # Validate cn to prevent path traversal
            cn_str = str(cn)
            if not re.match(r'^[a-zA-Z0-9_.-]{1,64}$', cn_str):
                raise ValueError('Invalid cn for secret file')
            os.makedirs(secret_dir, mode=0o700, exist_ok=True)
            secret_file = os.path.join(secret_dir, cn_str)
            # Verify path stays within secret_dir
            if not os.path.realpath(secret_file).startswith(
                    os.path.realpath(secret_dir)):
                raise ValueError('Path traversal detected')
            # DESIGN: O_NOFOLLOW prevents symlink attacks; ipaapi:ipaapi ownership
            # on the directory ensures only the WSGI process and daemon can access.
            fd = os.open(secret_file,
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                         0o600)
            with os.fdopen(fd, 'w') as f:
                f.write(plaintext)
        except Exception:
            # DESIGN: Non-fatal — if the file write fails (permissions, SELinux),
            # the LDAP hash is still stored. The daemon logs a warning and
            # Keycloak keeps its existing secret until manually re-synced.
            pass

        # Return the plaintext (shown only once) and entry info
        result = {
            'dn': str(dn),
            'cn': [cn],
            'oauth2clientsecret': [u'** SECRET SET **'],
            'secret': [plaintext],
        }

        return dict(
            summary=(u'Generated new secret for OAuth2 client "%s".\n'
                     u'Client secret: %s\n'
                     u'IMPORTANT: Copy this secret now. It will not be '
                     u'shown again.' % (cn, plaintext)),
            result=result,
            value=cn,
        )
