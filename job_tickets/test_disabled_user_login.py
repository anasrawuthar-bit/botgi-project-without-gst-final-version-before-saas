from django.test import TestCase, Client
from django.contrib.auth.models import User, Group
from django.urls import reverse
import json

class DisabledUserLoginTests(TestCase):
    def setUp(self):
        self.client = Client()
        self.tech_group, _ = Group.objects.get_or_create(name='Technicians')
        
        self.active_tech = User.objects.create_user(
            username='active_tech',
            password='password123',
            is_active=True
        )
        self.active_tech.groups.add(self.tech_group)

        self.disabled_tech = User.objects.create_user(
            username='disabled_tech',
            password='password123',
            is_active=False
        )
        self.disabled_tech.groups.add(self.tech_group)

    def test_active_user_can_login(self):
        response = self.client.post(reverse('login'), {
            'username': 'active_tech',
            'password': 'password123',
        }, follow=True)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.context['user'].is_authenticated)

    def test_active_user_wrong_password_shows_invalid_and_attempts(self):
        response = self.client.post(reverse('login'), {
            'username': 'active_tech',
            'password': 'wrongpassword',
        })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Invalid username or password')
        self.assertContains(response, 'Attempts remaining:')

    def test_disabled_user_shows_disabled_error(self):
        response = self.client.post(reverse('login'), {
            'username': 'disabled_tech',
            'password': 'password123',
        })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'User Account Disabled')
        self.assertContains(response, 'This user account is disabled. Please contact your administrator.')
        self.assertNotContains(response, 'Attempts remaining:')

    def test_disabled_user_with_wrong_password_shows_disabled_error(self):
        response = self.client.post(reverse('login'), {
            'username': 'disabled_tech',
            'password': 'anypassword',
        })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'User Account Disabled')
        self.assertContains(response, 'This user account is disabled. Please contact your administrator.')
        self.assertNotContains(response, 'Attempts remaining:')

    def test_mobile_api_disabled_user_login(self):
        response = self.client.post(
            reverse('mobile_api_login'),
            data=json.dumps({
                'username': 'disabled_tech',
                'password': 'password123',
            }),
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 403)
        data = response.json()
        self.assertEqual(data.get('error'), 'account_disabled')
        self.assertIn('disabled', data.get('message', '').lower())


class QRLinkAccessTests(TestCase):
    def setUp(self):
        from job_tickets.models import JobTicket, Client as JobClient, CompanyWorkspace
        self.client = Client()
        self.owner = User.objects.create_user(username='qr_ws_owner', password='password123')
        self.workspace = CompanyWorkspace.objects.create(name='Test WS', slug='test-ws', owner=self.owner)
        self.customer = JobClient.objects.create(
            name='Test Customer',
            phone='9876543210',
            workspace=self.workspace,
        )
        self.job = JobTicket.objects.create(
            job_code='GI-TEST-001',
            customer_name='Test Customer',
            customer_phone='9876543210',
            device_type='Laptop',
            reported_issue='Screen Broken',
            workspace=self.workspace,
            status='In Progress',
        )

    def test_direct_qr_url_without_token_redirects_and_opens_status(self):
        """Visiting /qr/<job_code>/ directly (as printed on invoice) works without token."""
        response = self.client.get(reverse('qr_access', args=[self.job.job_code]))
        self.assertEqual(response.status_code, 302)
        self.assertIn(f"/client-status/{self.job.job_code}/", response['Location'])
        self.assertIn('token=', response['Location'])

        # Following the redirect loads client_status successfully
        follow_response = self.client.get(response['Location'])
        self.assertEqual(follow_response.status_code, 200)
        self.assertContains(follow_response, 'GI-TEST-001')
        self.assertContains(follow_response, 'Laptop')

    def test_qr_url_with_invalid_token_returns_forbidden(self):
        response = self.client.get(f"{reverse('qr_access', args=[self.job.job_code])}?token=invalid.token")
        self.assertEqual(response.status_code, 403)
        self.assertIn('Invalid or expired QR link', response.content.decode('utf-8'))

