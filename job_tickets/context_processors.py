# job_tickets/context_processors.py
from django.conf import settings

from .access_control import get_staff_access
from .models import CompanyProfile, PlatformSettings
from .workspaces import get_current_workspace

def company_profile(request):
    """Make company profile available in all templates"""
    current_workspace = get_current_workspace(request)
    return {
        'app_name': getattr(settings, 'APP_NAME', 'ZynDesk'),
        'platform_company_name': getattr(settings, 'PLATFORM_COMPANY_NAME', 'CoreZyn'),
        'app_logo_url': getattr(settings, 'APP_LOGO_URL', 'https://image.gihostings.com/i/356b7bc7285f8ce2.jpeg'),
        'current_workspace': current_workspace,
        'company': CompanyProfile.get_profile(current_workspace),
        'platform': PlatformSettings.get_settings(),
        'staff_access': get_staff_access(getattr(request, 'user', None)),
        'release_info': {
            'web_version': getattr(settings, 'WEB_RELEASE_VERSION', 'dev'),
            'poll_interval_ms': max(getattr(settings, 'WEB_RELEASE_POLL_INTERVAL_SECONDS', 300), 60) * 1000,
        },
    }
