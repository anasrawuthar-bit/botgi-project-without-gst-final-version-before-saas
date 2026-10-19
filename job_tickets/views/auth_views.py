from .helpers import *  # noqa: F401,F403
from .helpers import (
    _get_permitted_next_url,
    _get_post_login_redirect,
    _get_safe_next_url,
)


def home(request):
    context = {
        'total_jobs': JobTicket.objects.count(),
        'total_clients': Client.objects.count(),
        'total_products': Product.objects.count(),
    }
    return render(request, 'job_tickets/home.html', context)


def unauthorized(request):
    return render(request, 'job_tickets/unauthorized.html')


@never_cache
def login_view(request):
    next_url = _get_safe_next_url(request)
    logout_reason = (request.GET.get('reason') or '').strip().lower()
    logout_notice = ''
    logout_notice_level = ''
    if logout_reason == 'session_replaced':
        logout_notice = 'You were logged out because this account signed in on another device.'
        logout_notice_level = 'warning'
    elif logout_reason == 'session_expired':
        logout_notice = 'Your session expired due to inactivity. Please log in again.'
        logout_notice_level = 'secondary'
    elif logout_reason == 'account_disabled':
        logout_notice = 'This user account is disabled. Please contact your administrator.'
        logout_notice_level = 'danger'

    if request.user.is_authenticated:
        permitted_next_url = _get_permitted_next_url(request.user, next_url)
        if permitted_next_url:
            return redirect(permitted_next_url)
        return _get_post_login_redirect(request.user)

    if request.method == 'POST':
        username = request.POST.get('username', '').strip()
        password = request.POST.get('password', '')

        client_ip = request.META.get('REMOTE_ADDR')
        cache_key = f'login_attempts_{client_ip}'
        attempts = cache.get(cache_key, 0)

        if attempts >= 5:
            return render(request, 'job_tickets/login.html', {
                'error': 'Too many failed attempts. Please try again in 15 minutes.',
                'locked': True,
                'logout_notice': logout_notice,
                'logout_notice_level': logout_notice_level,
            })

        user = authenticate(request, username=username, password=password)
        if user is not None:
            if not user.is_active:
                return render(request, 'job_tickets/login.html', {
                    'error': 'This user account is disabled. Please contact your administrator.',
                    'is_disabled': True,
                    'username': username,
                    'next': next_url,
                    'logout_notice': logout_notice,
                    'logout_notice_level': logout_notice_level,
                })
            cache.delete(cache_key)
            login(request, user)
            request.session.set_expiry(settings.SESSION_IDLE_TIMEOUT_SECONDS)
            permitted_next_url = _get_permitted_next_url(user, next_url)
            if permitted_next_url:
                return redirect(permitted_next_url)
            return _get_post_login_redirect(user)

        # Check if the account exists and is disabled
        candidate_user = User.objects.filter(username__iexact=username).first()
        if candidate_user and not candidate_user.is_active:
            return render(request, 'job_tickets/login.html', {
                'error': 'This user account is disabled. Please contact your administrator.',
                'is_disabled': True,
                'username': username,
                'next': next_url,
                'logout_notice': logout_notice,
                'logout_notice_level': logout_notice_level,
            })

        cache.set(cache_key, attempts + 1, 900)
        return render(request, 'job_tickets/login.html', {
            'error': 'Invalid username or password',
            'username': username,
            'next': next_url,
            'attempts_left': 4 - attempts,
            'logout_notice': logout_notice,
            'logout_notice_level': logout_notice_level,
        })

    return render(
        request,
        'job_tickets/login.html',
        {
            'next': next_url,
            'logout_notice': logout_notice,
            'logout_notice_level': logout_notice_level,
            'logout_reason': logout_reason,
        },
    )


@never_cache
def logout_view(request):
    request._audit_session_key = request.session.session_key
    request._session_logout_reason = UserSessionActivity.STATUS_LOGGED_OUT
    request._session_was_terminated = True
    logout(request)
    return redirect('home')
