#
# IPA OAuth2 Token Introspection Plugin
#
# Proxies token introspection requests to the configured IdP's RFC 7662
# endpoint. Supports Keycloak (via Admin API) and ekishib (via SPNEGO).
#

import base64
import json
import os
import time

import requests as http_requests
from requests_gssapi import HTTPSPNEGOAuth

from ipalib import _, Command, Str, output
from ipalib.plugable import Registry

register = Registry()

# Product-aware config paths (PoC → Product migration)
_CONFIG_SEARCH_PATHS = [
    '/etc/ipa-wid/obo/obo.conf',
    '/etc/ipa/oauth2d/oauth2d.conf',  # PoC fallback
]

_KC_PASSWORD_SEARCH_PATHS = [
    '/etc/ipa-wid/credentials/keycloak.passwd',
    '/etc/ipa/oauth2d/keycloak.passwd',  # PoC fallback
]


def _find_path(paths):
    """Find first existing path from list."""
    for p in paths:
        if os.path.exists(p):
            return p
    return None


_CONFIG_FILE = _find_path(_CONFIG_SEARCH_PATHS)
_KC_PASSWORD_FILE = _find_path(_KC_PASSWORD_SEARCH_PATHS)


def _load_idp_config():
    """Read IdP connection settings from the daemon config file."""
    config = {
        'idp_type': 'keycloak',
        'keycloak_url': 'http://localhost:8180/auth',
        'keycloak_realm': 'ipa',
        'keycloak_admin_user': 'admin',
        'keycloak_verify_ssl': 'false',
        'ekishib_url': 'http://localhost:8180',
        'request_timeout': '10',
    }

    if _CONFIG_FILE and os.path.exists(_CONFIG_FILE):
        with open(_CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()

    pw_file = config.get('keycloak_admin_password_file', _KC_PASSWORD_FILE)
    if pw_file and os.path.exists(pw_file):
        with open(pw_file) as f:
            config['keycloak_admin_password'] = f.read().strip()

    return config


def _get_admin_token(config):
    """Obtain a Keycloak admin access token."""
    url = config['keycloak_url'].rstrip('/')
    verify = config.get('keycloak_verify_ssl', 'false').lower() in ('true', '1', 'yes')
    timeout = int(config.get('request_timeout', 10))

    resp = http_requests.post(
        f'{url}/realms/master/protocol/openid-connect/token',
        data={
            'client_id': 'admin-cli',
            'username': config['keycloak_admin_user'],
            'password': config['keycloak_admin_password'],
            'grant_type': 'password',
        },
        timeout=timeout,
        verify=verify,
    )
    resp.raise_for_status()
    return resp.json()['access_token']


def _introspect_ekishib(token, config):
    """Introspect via ekishib using SPNEGO (kerberos_client_auth)."""
    url = config.get('ekishib_url', 'http://localhost:8180').rstrip('/')
    verify = config.get('keycloak_verify_ssl', 'false').lower() in ('true', '1', 'yes')
    timeout = int(config.get('request_timeout', 10))

    resp = http_requests.post(
        f'{url}/oauth2/introspect',
        data={'token': token},
        auth=HTTPSPNEGOAuth(),
        timeout=timeout,
        verify=verify,
    )
    resp.raise_for_status()
    return resp.json()


_AHDAPA_KEYTAB_SEARCH_PATHS = [
    '/etc/ipa-wid/credentials/oauth2d.keytab',
    '/etc/ipa/oauth2d/oauth2d.keytab',  # PoC fallback
]
_AHDAPA_KEYTAB = _find_path(_AHDAPA_KEYTAB_SEARCH_PATHS)

# Ccache under /run (tmpfs, owned root, mode 700 by systemd-tmpfiles or ExecStartPre).
# Avoids /tmp which is world-readable and allows any process to steal the token.
# Falls back to a process-private tempdir if /run/ipa/oauth2d is unavailable.
_AHDAPA_CCACHE_DIR = '/run/ipa-wid'  # Product path
_AHDAPA_CCACHE = 'FILE:/run/ipa-wid/ahdapa-introspect.ccache'

# NOTE FOR AHDAPA MAINTAINERS (AB):
# Cross-client introspection is not currently possible via this plugin.
#
# ahdapa's /introspect endpoint is client-scoped: a client can only introspect
# tokens it issued.  The IPA plugin authenticates as oauth2d/<fqdn>@REALM,
# which only matches clients with kerberos_principal_pattern = *@REALM.
# Tokens issued to clients with a narrower pattern (e.g. host/*@REALM for
# host-agents) return {"active": false} when the plugin introspects them —
# even though the token is valid and unexpired.
#
# What we'd need from ahdapa to fix this:
#   Option A: A privileged introspection role/scope allowing a trusted service
#             principal (e.g. oauth2d/) to introspect any token, similar to
#             Keycloak's admin API cross-client introspection.
#   Option B: Per-client allow_introspect_by list, so host-agents could
#             explicitly authorize oauth2d/ to introspect its tokens.
#
# Current workaround: plugin works for test-xchg-client tokens (*@REALM
# pattern matches oauth2d/).  FDO device tokens (host-agents) are not
# introspectable via ipa oauth2token-introspect — devices use their token
# directly against ahdapa; they don't need IPA to introspect it.


def _ahdapa_gssapi_token(server_hostname):
    """Obtain a base64-encoded GSSAPI Negotiate token for ahdapa.

    Uses the oauth2d service keytab (readable by ipaapi) to kinit, then
    creates a security context targeting HTTP/<ahdapa-host>.  Returns None
    if the keytab is missing or GSSAPI fails.
    """
    import subprocess
    import gssapi

    if not os.path.exists(_AHDAPA_KEYTAB):
        return None

    principal = None
    try:
        result = subprocess.run(
            ['klist', '-k', _AHDAPA_KEYTAB],
            capture_output=True, text=True,
        )
        for line in result.stdout.splitlines():
            if '@' in line and 'oauth2d/' in line:
                principal = line.split()[-1]
                break
    except Exception:
        return None

    if not principal:
        return None

    # Use /run/ipa/oauth2d (tmpfs, root-owned) for ccache storage.
    # Fall back to a process-private temp directory if unavailable.
    import tempfile
    ccache_path = _AHDAPA_CCACHE
    tmp_dir = None
    if not os.path.isdir(_AHDAPA_CCACHE_DIR):
        tmp_dir = tempfile.mkdtemp(prefix='ipa-ahdapa-', dir='/run')
        os.chmod(tmp_dir, 0o700)
        ccache_path = f'FILE:{tmp_dir}/introspect.ccache'

    try:
        subprocess.run(
            ['kinit', '-k', '-t', _AHDAPA_KEYTAB, '-c', ccache_path,
             principal],
            check=True, capture_output=True,
        )
        old_ccache = os.environ.get('KRB5CCNAME', '')
        os.environ['KRB5CCNAME'] = ccache_path
        try:
            name = gssapi.Name(
                f'HTTP@{server_hostname}',
                gssapi.NameType.hostbased_service,
            )
            ctx = gssapi.SecurityContext(name=name, usage='initiate')
            import base64 as _b64
            return _b64.b64encode(ctx.step()).decode()
        finally:
            if old_ccache:
                os.environ['KRB5CCNAME'] = old_ccache
            else:
                os.environ.pop('KRB5CCNAME', None)
            # Destroy the ccache immediately — don't leave credentials on disk
            subprocess.run(['kdestroy', '-c', ccache_path],
                           capture_output=True)
    except Exception:
        return None
    finally:
        if tmp_dir:
            import shutil
            shutil.rmtree(tmp_dir, ignore_errors=True)


def _introspect_ahdapa(token, config, client_id=None):
    """Introspect via ahdapa using SPNEGO (kerberos_client_auth).

    ahdapa's RFC 7662 introspect endpoint requires the caller to authenticate
    as a registered client.  Uses the oauth2d service keytab so the IPA WSGI
    process (ipaapi) doesn't need ambient Kerberos credentials.
    """
    url = config.get('ahdapa_url', 'http://localhost:8099').rstrip('/')
    verify = config.get('ahdapa_verify_ssl', 'false').lower() in ('true', '1', 'yes')
    timeout = int(config.get('request_timeout', 10))
    introspect_client = config.get('ahdapa_introspect_client', 'test-xchg-client')

    # For GSSAPI, the target must be the real FQDN of the ahdapa server
    # (not 'localhost' even when ahdapa_url uses localhost).
    # Use an explicit config key, falling back to the IPA server's own FQDN.
    from urllib.parse import urlparse
    parsed = urlparse(url)
    raw_host = parsed.hostname or 'localhost'
    if raw_host in ('localhost', '127.0.0.1', '::1'):
        import socket
        server_host = config.get('ahdapa_gssapi_host', socket.getfqdn())
    else:
        server_host = raw_host

    # Try keytab-based GSSAPI first
    # ahdapa introspect is client-scoped (RFC 7662): a token is only reported
    # active for the client that issued it.  The ahdapa_introspect_client must
    # be the same client whose tokens are being introspected, and its
    # kerberos_principal_pattern must match the oauth2d service principal.
    # Default: test-xchg-client (pattern: *@OAUTH2.TEST, matches oauth2d/).
    effective_client_id = client_id or introspect_client

    gss_token = _ahdapa_gssapi_token(server_host)
    if gss_token:
        auth_header = f'Negotiate {gss_token}'
        body = {'token': token, 'client_id': effective_client_id}
        resp = http_requests.post(
            f'{url}/introspect',
            data=body,
            headers={'Authorization': auth_header},
            timeout=timeout,
            verify=verify,
        )
    else:
        # Fallback: ambient GSSAPI credentials via requests_gssapi
        body = {'token': token, 'client_id': effective_client_id}
        resp = http_requests.post(
            f'{url}/introspect',
            data=body,
            auth=HTTPSPNEGOAuth(),
            timeout=timeout,
            verify=verify,
        )

    resp.raise_for_status()
    return resp.json()


@register()
class oauth2token_introspect(Command):
    __doc__ = _('Introspect an OAuth2 access token (RFC 7662).')

    takes_args = (
        Str(
            'token',
            label=_('Access token'),
            doc=_('The OAuth2 access token to introspect'),
        ),
    )

    takes_options = (
        Str(
            'oauth2clientid?',
            cli_name='client_id',
            label=_('Client ID'),
            doc=_('Client ID context for introspection (optional)'),
        ),
    )

    has_output = (
        output.summary,
        output.Entry('result'),
        output.Output('value', type=str),
    )

    def execute(self, token, **options):
        config = _load_idp_config()
        idp_type = config.get('idp_type', 'keycloak')

        if idp_type == 'ekishib':
            introspection = _introspect_ekishib(token, config)
            return self._format_result(introspection)

        if idp_type == 'ahdapa':
            client_id = options.get('oauth2clientid') or None
            introspection = _introspect_ahdapa(token, config, client_id=client_id)
            return self._format_result(introspection)

        if 'keycloak_admin_password' not in config:
            from ipalib.errors import ValidationError
            raise ValidationError(
                name='keycloak_config',
                error=_('Keycloak admin password not configured. '
                        'Ensure %s exists.') % _KC_PASSWORD_FILE,
            )

        url = config['keycloak_url'].rstrip('/')
        realm = config['keycloak_realm']
        verify = config.get('keycloak_verify_ssl', 'false').lower() in ('true', '1', 'yes')
        timeout = int(config.get('request_timeout', 10))

        # Introspect via the Keycloak Admin REST API instead of the
        # OIDC introspection endpoint, since admin-cli has admin access
        # to all realms.
        admin_token = _get_admin_token(config)

        # Decode the token to extract the client info without validation
        # (Keycloak will do the real validation)
        try:
            # JWT payload is the second segment
            payload_b64 = token.split('.')[1]
            # Fix padding
            payload_b64 += '=' * (4 - len(payload_b64) % 4)
            payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        except Exception:
            payload = {}

        # Use the userinfo endpoint with the token to verify it's active,
        # or fall back to calling the introspection endpoint with client
        # credentials from a confidential client in the realm.
        # Strategy: find the first confidential client we manage and use
        # its credentials from the Keycloak Admin API.
        introspect_url = (
            f'{url}/realms/{realm}/protocol/openid-connect/token/introspect'
        )

        # Get the client that issued the token (azp claim)
        azp = payload.get('azp', '')

        # Use admin API to get the client's secret from Keycloak
        clients_url = f'{url}/admin/realms/{realm}/clients'
        clients_resp = http_requests.get(
            clients_url,
            headers={'Authorization': f'Bearer {admin_token}'},
            params={'clientId': azp} if azp else {'max': 1},
            timeout=timeout,
            verify=verify,
        )
        clients_resp.raise_for_status()
        clients_list = clients_resp.json()

        if clients_list and not clients_list[0].get('publicClient', True):
            kc_client_id = clients_list[0]['id']
            # Get the client's actual secret from Keycloak
            secret_resp = http_requests.get(
                f'{clients_url}/{kc_client_id}/client-secret',
                headers={'Authorization': f'Bearer {admin_token}'},
                timeout=timeout,
                verify=verify,
            )
            secret_resp.raise_for_status()
            client_secret = secret_resp.json().get('value', '')

            resp = http_requests.post(
                introspect_url,
                data={
                    'token': token,
                    'client_id': azp,
                    'client_secret': client_secret,
                },
                timeout=timeout,
                verify=verify,
            )
        else:
            # No confidential client found — token is invalid/malformed
            introspection = {'active': False}
            resp = None

        if resp is not None:
            resp.raise_for_status()
            introspection = resp.json()

        return self._format_result(introspection)

    def _format_result(self, introspection):
        active = introspection.get('active', False)
        result = {}
        for key in ('active', 'sub', 'scope', 'client_id', 'username',
                     'token_type', 'exp', 'iat', 'iss', 'aud'):
            val = introspection.get(key)
            if val is not None:
                result[key] = [str(val)]

        if active:
            username = introspection.get('username', 'unknown')
            scope = introspection.get('scope', '')
            summary = u'Token is ACTIVE (user=%s, scope=%s)' % (
                username, scope)
        else:
            summary = u'Token is INACTIVE or expired'

        return dict(
            summary=summary,
            result=result,
            value=u'active' if active else u'inactive',
        )
