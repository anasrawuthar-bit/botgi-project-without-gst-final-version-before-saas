import json
import uuid
from decimal import Decimal
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.contrib.auth.models import User, Group
from django.test import TestCase, Client
from django.urls import reverse

from job_tickets.models import (
    CompanyUserMembership,
    CompanyWorkspace,
    JobTicket,
    Task,
    TaskAttachment,
    TechnicianProfile,
    UserSessionActivity,
)
from job_tickets.views.helpers import issue_mobile_jwt


class MobileApiSecurityTests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = Client()
        self.tech_group, _ = Group.objects.get_or_create(name='Technicians')
        self.staff_group, _ = Group.objects.get_or_create(name='Staff')

        # Company 1
        self.owner1 = User.objects.create_user(username='owner1', password='password123', is_staff=True)
        self.ws1 = CompanyWorkspace.objects.create(name='Workspace 1', slug='ws1', owner=self.owner1)
        CompanyUserMembership.objects.create(
            workspace=self.ws1, user=self.owner1, role=CompanyUserMembership.ROLE_ADMIN, is_active=True
        )

        # Tech in Company 1
        self.tech_user1 = User.objects.create_user(username='tech1', password='password123', is_active=True)
        self.tech_user1.groups.add(self.tech_group)
        self.tech_profile1 = TechnicianProfile.objects.create(
            workspace=self.ws1, user=self.tech_user1, unique_id='TECH01'
        )
        CompanyUserMembership.objects.create(
            workspace=self.ws1, user=self.tech_user1, role=CompanyUserMembership.ROLE_TECHNICIAN, is_active=True
        )

        # Disabled tech
        self.disabled_tech = User.objects.create_user(username='disabled_tech', password='password123', is_active=False)
        self.disabled_tech.groups.add(self.tech_group)
        self.disabled_tech_profile = TechnicianProfile.objects.create(
            workspace=self.ws1, user=self.disabled_tech, unique_id='TECH_DIS'
        )

        # Company 2
        self.owner2 = User.objects.create_user(username='owner2', password='password123', is_staff=True)
        self.ws2 = CompanyWorkspace.objects.create(name='Workspace 2', slug='ws2', owner=self.owner2)
        CompanyUserMembership.objects.create(
            workspace=self.ws2, user=self.owner2, role=CompanyUserMembership.ROLE_ADMIN, is_active=True
        )

        # Task in Company 2
        self.task_company2 = Task.objects.create(
            workspace=self.ws2,
            title='Confidential Company 2 Task',
            description='Secret server repair',
            priority=Task.PRIORITY_URGENT,
            created_by=self.owner2,
        )

        # Task in Company 1 assigned to tech1
        self.task_company1 = Task.objects.create(
            workspace=self.ws1,
            title='Company 1 Assigned Task',
            description='Screen repair task',
            priority=Task.PRIORITY_MEDIUM,
            assigned_to=self.tech_profile1,
            created_by=self.owner1,
        )

    def tearDown(self):
        cache.clear()

    def test_mobile_login_success(self):
        response = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({'username': 'tech1', 'password': 'password123'}),
            content_type='application/json',
        )
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn('access_token', data)
        self.assertEqual(data['user']['username'], 'tech1')

    def test_mobile_login_rate_limiting(self):
        """5 failed login attempts trigger 429 Too Many Requests."""
        for attempt in range(5):
            resp = self.client.post(
                reverse('mobile_api_login'),
                data=json.dumps({'username': 'tech1', 'password': 'wrongpassword'}),
                content_type='application/json',
            )
            self.assertEqual(resp.status_code, 401)

        # 6th attempt should be blocked with 429
        blocked_resp = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({'username': 'tech1', 'password': 'password123'}),
            content_type='application/json',
        )
        self.assertEqual(blocked_resp.status_code, 429)
        self.assertEqual(blocked_resp.json().get('error'), 'rate_limited')

    def test_disabled_user_login_does_not_enumerate_with_wrong_password(self):
        """Entering wrong password for a disabled user returns 401, not 403."""
        response = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({'username': 'disabled_tech', 'password': 'wrongpassword'}),
            content_type='application/json',
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json().get('error'), 'invalid_credentials')

    def test_disabled_user_login_shows_disabled_only_with_correct_password(self):
        """Entering correct password for a disabled user safely shows account disabled error."""
        response = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({'username': 'disabled_tech', 'password': 'password123'}),
            content_type='application/json',
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json().get('error'), 'account_disabled')

    def test_mobile_api_logout_invalidates_session(self):
        """Calling /api/mobile/logout/ revokes the session in UserSessionActivity and invalidates the token."""
        login_resp = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({'username': 'tech1', 'password': 'password123'}),
            content_type='application/json',
        )
        self.assertEqual(login_resp.status_code, 200)
        token = login_resp.json()['access_token']

        # Verify token works on protected endpoint
        me_resp = self.client.get(
            reverse('mobile_api_me'),
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(me_resp.status_code, 200)

        # Logout
        logout_resp = self.client.post(
            reverse('mobile_api_logout'),
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(logout_resp.status_code, 200)
        self.assertTrue(logout_resp.json()['ok'])

        # Now try to use the token again - should be rejected with 401 session_revoked
        me_after_resp = self.client.get(
            reverse('mobile_api_me'),
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(me_after_resp.status_code, 401)
        self.assertEqual(me_after_resp.json().get('error'), 'session_revoked')

    def test_task_workspace_isolation(self):
        """Technician in Workspace 1 cannot access or upload files to a task in Workspace 2."""
        session_id = uuid.uuid4().hex
        UserSessionActivity.objects.create(
            user=self.tech_user1,
            session_key=session_id,
            channel=UserSessionActivity.CHANNEL_API,
            status=UserSessionActivity.STATUS_ACTIVE,
        )
        token = issue_mobile_jwt(self.tech_user1, session_id=session_id)

        # Try to view task in Company 2
        detail_resp = self.client.get(
            reverse('mobile_api_task_detail', args=[self.task_company2.id]),
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(detail_resp.status_code, 404)

        # Try to upload attachment to task in Company 2
        test_file = SimpleUploadedFile("test_report.pdf", b"test pdf content", content_type="application/pdf")
        upload_resp = self.client.post(
            reverse('mobile_api_task_attachment_upload', args=[self.task_company2.id]),
            {'file': test_file},
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(upload_resp.status_code, 404)

    def test_task_attachment_file_validation(self):
        """Dangerous file extensions (.exe, .sh) are rejected with 400."""
        session_id = uuid.uuid4().hex
        UserSessionActivity.objects.create(
            user=self.tech_user1,
            session_key=session_id,
            channel=UserSessionActivity.CHANNEL_API,
            status=UserSessionActivity.STATUS_ACTIVE,
        )
        token = issue_mobile_jwt(self.tech_user1, session_id=session_id)

        malicious_file = SimpleUploadedFile("exploit.exe", b"MZ...", content_type="application/octet-stream")
        upload_resp = self.client.post(
            reverse('mobile_api_task_attachment_upload', args=[self.task_company1.id]),
            {'file': malicious_file},
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(upload_resp.status_code, 400)
        self.assertEqual(upload_resp.json().get('error'), 'invalid_file')

        # Legitimate photo/pdf works
        legit_file = SimpleUploadedFile("diagnostic.png", b"\x89PNG\r\n\x1a\n...", content_type="image/png")
        legit_resp = self.client.post(
            reverse('mobile_api_task_attachment_upload', args=[self.task_company1.id]),
            {'file': legit_file},
            HTTP_AUTHORIZATION=f'Bearer {token}',
        )
        self.assertEqual(legit_resp.status_code, 200)
        self.assertTrue(legit_resp.json()['ok'])
