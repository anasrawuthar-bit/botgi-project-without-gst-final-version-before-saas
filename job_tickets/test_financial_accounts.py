from decimal import Decimal
from django.contrib.auth.models import User
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from job_tickets.access_control import apply_staff_access
from job_tickets.models import (
    AccountTransaction,
    CompanyUserMembership,
    CompanyWorkspace,
    Expense,
    FinancialAccount,
    JobTicket,
    ServiceLog,
)


class FinancialAccountsTestCase(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username="accounts_staff",
            password="password123",
            is_staff=True,
        )
        self.workspace = CompanyWorkspace.objects.create(
            name="Test Service Hub",
            slug="test-hub",
            status=CompanyWorkspace.STATUS_ACTIVE,
            owner=self.user,
        )
        CompanyUserMembership.objects.create(
            workspace=self.workspace,
            user=self.user,
            role=CompanyUserMembership.ROLE_STAFF,
            is_active=True,
        )

        # Seed default accounts
        FinancialAccount.ensure_default_accounts(self.workspace)
        self.cash_acc = FinancialAccount.get_default_cash_account(self.workspace)
        self.bank_acc = FinancialAccount.get_default_bank_account(self.workspace)

    def test_default_accounts_seeded_with_zero_balance(self):
        self.assertIsNotNone(self.cash_acc)
        self.assertIsNotNone(self.bank_acc)
        self.assertEqual(self.cash_acc.current_balance, Decimal('0.00'))
        self.assertEqual(self.bank_acc.current_balance, Decimal('0.00'))
        self.assertTrue(self.cash_acc.is_default_cash)
        self.assertTrue(self.bank_acc.is_default_bank)

    def test_create_multiple_accounts_and_set_defaults(self):
        # Create a petty cash account
        petty_cash = FinancialAccount.objects.create(
            workspace=self.workspace,
            name="Petty Cash Register",
            account_type=FinancialAccount.ACCOUNT_TYPE_CASH,
            opening_balance=Decimal('100.00'),
            current_balance=Decimal('100.00'),
        )
        self.assertEqual(petty_cash.current_balance, Decimal('100.00'))
        self.assertFalse(petty_cash.is_default_cash)

        # Switch default cash to Petty Cash
        petty_cash.is_default_cash = True
        petty_cash.save()

        # Reload old cash_acc: should no longer be default cash
        self.cash_acc.refresh_from_db()
        self.assertFalse(self.cash_acc.is_default_cash)
        self.assertTrue(petty_cash.is_default_cash)

    def test_self_transfer_between_accounts(self):
        # Initial deposit into cash account
        self.cash_acc.deposit(
            amount=Decimal('5000.00'),
            description="Initial Register Float",
            user=self.user,
        )
        self.cash_acc.refresh_from_db()
        self.assertEqual(self.cash_acc.current_balance, Decimal('5000.00'))

        # Transfer 2000 from cash to bank (Cash deposit to Federal Bank)
        txn_out, txn_in = FinancialAccount.transfer(
            from_account=self.cash_acc,
            to_account=self.bank_acc,
            amount=Decimal('2000.00'),
            reference_no="CDM-88912",
            notes="End of day cash deposit",
            user=self.user,
        )

        self.cash_acc.refresh_from_db()
        self.bank_acc.refresh_from_db()

        self.assertEqual(self.cash_acc.current_balance, Decimal('3000.00'))
        self.assertEqual(self.bank_acc.current_balance, Decimal('2000.00'))

        # Verify counterpart transaction linkage
        self.assertEqual(txn_out.transfer_counterpart_id, txn_in.pk)
        self.assertEqual(txn_in.transfer_counterpart_id, txn_out.pk)
        self.assertEqual(txn_out.transaction_type, AccountTransaction.TYPE_TRANSFER_OUT)
        self.assertEqual(txn_in.transaction_type, AccountTransaction.TYPE_TRANSFER_IN)
        self.assertEqual(txn_out.amount, Decimal('2000.00'))
        self.assertEqual(txn_in.amount, Decimal('2000.00'))

    def test_expense_outflow_and_deletion_balance_restoration(self):
        # Fund bank account
        self.bank_acc.deposit(
            amount=Decimal('10000.00'),
            description="Bank Float",
            user=self.user,
        )
        self.bank_acc.refresh_from_db()
        self.assertEqual(self.bank_acc.current_balance, Decimal('10000.00'))

        self.client.login(username="accounts_staff", password="password123")

        # Record expense paid from bank
        response = self.client.post(reverse('expense_create'), {
            'title': 'Shop Electricity Bill',
            'amount': '1500.00',
            'category': Expense.CATEGORY_UTILITIES,
            'payment_mode': Expense.PAYMENT_MODE_BANK,
            'financial_account': self.bank_acc.pk,
            'expense_date': str(timezone.localdate()),
        }, follow=True)
        self.assertEqual(response.status_code, 200)

        self.bank_acc.refresh_from_db()
        self.assertEqual(self.bank_acc.current_balance, Decimal('8500.00'))

        expense = Expense.objects.filter(title='Shop Electricity Bill').first()
        self.assertIsNotNone(expense)
        self.assertEqual(expense.financial_account_id, self.bank_acc.pk)
        self.assertEqual(expense.account_transactions.count(), 1)

        # Delete the expense: balance should be restored to 10000.00
        delete_resp = self.client.post(reverse('expense_delete', args=[expense.id]), follow=True)
        self.assertEqual(delete_resp.status_code, 200)

        self.bank_acc.refresh_from_db()
        self.assertEqual(self.bank_acc.current_balance, Decimal('10000.00'))
        self.assertFalse(Expense.objects.filter(id=expense.id).exists())

    def test_job_settlement_inflow(self):
        job = JobTicket.objects.create(
            workspace=self.workspace,
            job_code="GI-260929-001",
            customer_name="Test Customer",
            customer_phone="9876543210",
            device_type="Laptop",
            status="Ready for Pickup",
            created_by=self.user,
        )
        ServiceLog.objects.create(
            job_ticket=job,
            description="Screen Replacement",
            part_cost=Decimal('1000.00'),
            service_charge=Decimal('500.00'),
        )

        self.client.login(username="accounts_staff", password="password123")

        # Close job with Cash payment of 1200
        response = self.client.post(reverse('close_job', args=[job.job_code]), {
            'payment_status': 'part_paid',
            'amount_paid': '1200.00',
            'payment_method': 'cash',
            'financial_account': self.cash_acc.pk,
        }, follow=True)
        self.assertEqual(response.status_code, 200)

        self.cash_acc.refresh_from_db()
        self.assertEqual(self.cash_acc.current_balance, Decimal('1200.00'))

        job.refresh_from_db()
        self.assertEqual(job.status, 'Closed')
        self.assertEqual(job.amount_paid, Decimal('1200.00'))
        self.assertEqual(job.financial_account_id, self.cash_acc.pk)

        # AccountTransaction logged for job
        txn = job.account_transactions.filter(transaction_type=AccountTransaction.TYPE_INFLOW).first()
        self.assertIsNotNone(txn)
        self.assertEqual(txn.amount, Decimal('1200.00'))
        self.assertEqual(txn.account_id, self.cash_acc.pk)

    def test_daily_daybook_reconciliation(self):
        from job_tickets.views.helpers import get_daily_daybook_context

        # Set balances: Deposit 1200 into Cash, spend 200 on expense, transfer 500 to Bank
        self.cash_acc.deposit(Decimal('1200.00'), "Customer Job Payment", user=self.user)
        Expense.objects.create(
            workspace=self.workspace,
            category="Shop Tea & Snacks",
            amount=Decimal('200.00'),
            financial_account=self.cash_acc,
            recorded_by=self.user,
        )
        self.cash_acc.withdraw(Decimal('200.00'), "Expense: Shop Tea", user=self.user)

        # Contra transfer 500 from cash to bank
        FinancialAccount.transfer(
            from_account=self.cash_acc,
            to_account=self.bank_acc,
            amount=Decimal('500.00'),
            user=self.user,
            reference_no="SLIP-9988",
            description="End-of-day bank cash deposit",
        )

        self.cash_acc.refresh_from_db()
        self.bank_acc.refresh_from_db()
        # Cash should be 1200 - 200 - 500 = 500
        self.assertEqual(self.cash_acc.current_balance, Decimal('500.00'))
        # Bank should be 0 + 500 = 500
        self.assertEqual(self.bank_acc.current_balance, Decimal('500.00'))

        today = timezone.localdate()
        daybook = get_daily_daybook_context(today, workspace=self.workspace)

        self.assertEqual(daybook['opening_cash'], Decimal('0.00'))
        self.assertEqual(daybook['cash_inflows'], Decimal('1200.00'))
        self.assertEqual(daybook['cash_outflows'], Decimal('200.00'))
        self.assertEqual(daybook['cash_to_bank'], Decimal('500.00'))
        self.assertEqual(daybook['bank_to_cash'], Decimal('0.00'))
        self.assertEqual(daybook['expected_drawer_cash'], Decimal('500.00'))
        self.assertEqual(daybook['closing_cash'], Decimal('500.00'))
        self.assertEqual(daybook['bank_inflows'], Decimal('0.00'))
        self.assertEqual(daybook['net_bank_flow'], Decimal('500.00'))
        self.assertEqual(daybook['total_liquid_balance'], Decimal('1000.00'))

    def test_daybook_views_and_exports(self):
        from job_tickets.access_control import apply_staff_access
        apply_staff_access(self.user, ["reports_dashboard", "reports_financial", "staff_dashboard"])

        self.client.login(username="accounts_staff", password="password123")

        # 1. Reports Dashboard with Daybook Tab
        resp = self.client.get(reverse('reports_dashboard') + '?tab=daybook')
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'Daily Daybook &amp; Reconciliation')
        self.assertContains(resp, 'Physical Cash Drawer')

        # 2. Printable Daybook Report
        resp_print = self.client.get(reverse('print_daily_daybook_report'))
        self.assertEqual(resp_print.status_code, 200)
        self.assertContains(resp_print, 'Physical Cash Drawer Statement')
        self.assertContains(resp_print, 'Expected Physical Cash in Drawer')

        # 3. Export Daybook CSV
        resp_csv = self.client.get(reverse('export_daily_daybook_csv'))
        self.assertEqual(resp_csv.status_code, 200)
        self.assertEqual(resp_csv['Content-Type'], 'text/csv')
        self.assertIn('CASH DRAWER RECONCILIATION', resp_csv.content.decode('utf-8'))

    def test_company_profile_transaction_ledger(self):
        from job_tickets.access_control import apply_staff_access
        apply_staff_access(self.user, ["company_settings"])
        self.client.login(username="accounts_staff", password="password123")

        job = JobTicket.objects.create(
            workspace=self.workspace,
            job_code="GI-260929-777",
            customer_name="Ledger Customer",
            customer_phone="9876543210",
            device_type="Laptop",
            status="In Progress",
            created_by=self.user,
        )

        # Deposit into cash with job ticket and withdraw
        self.cash_acc.deposit(
            amount=Decimal('1500.00'),
            description="Intake Payment for Job #GI-260929-777",
            reference_no="INV-101",
            job_ticket=job,
            user=self.user,
        )
        self.cash_acc.withdraw(
            amount=Decimal('300.00'),
            description="Shop cleaning expense",
            reference_no="EXP-44",
            user=self.user,
        )
        # Contra transfer
        FinancialAccount.transfer(
            from_account=self.cash_acc,
            to_account=self.bank_acc,
            amount=Decimal('400.00'),
            reference_no="CONTRA-99",
            description="Cash deposit to bank",
            user=self.user,
        )

        # 1. Access company profile settings with bank-details tab
        url = reverse('company_profile_settings') + '?tab=bank-details'
        resp = self.client.get(url)
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'Financial Ledger &amp; Transaction History')
        self.assertContains(resp, 'Intake Payment for Job #GI-260929-777')
        self.assertContains(resp, 'Job #GI-260929-777')
        self.assertContains(resp, reverse('staff_job_detail', args=[job.job_code]))
        self.assertContains(resp, 'Shop cleaning expense')
        self.assertContains(resp, 'CONTRA-99')
        self.assertContains(resp, '+&#8377;1500.00')
        self.assertContains(resp, '-&#8377;300.00')

        # 2. Filter by account_id
        url_acc = reverse('company_profile_settings') + f'?tab=bank-details&account_id={self.bank_acc.id}'
        resp_acc = self.client.get(url_acc)
        self.assertEqual(resp_acc.status_code, 200)
        self.assertContains(resp_acc, 'CONTRA-99')
        self.assertNotContains(resp_acc, 'Shop cleaning expense')

        # 3. Filter by type=inflow
        url_inflow = reverse('company_profile_settings') + '?tab=bank-details&txn_type=inflow'
        resp_inflow = self.client.get(url_inflow)
        self.assertEqual(resp_inflow.status_code, 200)
        self.assertContains(resp_inflow, 'Intake Payment for Job #GI-260929-777')
        self.assertNotContains(resp_inflow, 'Shop cleaning expense')

        # 4. Filter by search query
        url_search = reverse('company_profile_settings') + '?tab=bank-details&q=cleaning'
        resp_search = self.client.get(url_search)
        self.assertEqual(resp_search.status_code, 200)
        self.assertContains(resp_search, 'Shop cleaning expense')
        self.assertNotContains(resp_search, 'Intake Payment for Job #GI-260929-777')

    def test_account_deletion_safeguards_and_reactivation(self):
        from job_tickets.access_control import apply_staff_access
        apply_staff_access(self.user, ["company_settings"])
        self.client.login(username="accounts_staff", password="password123")

        # 1. Try to delete active Default Cash account -> Blocked
        resp = self.client.post(reverse('account_delete', args=[self.cash_acc.id]), follow=True)
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, "Cannot delete or deactivate")
        self.assertTrue(FinancialAccount.objects.filter(id=self.cash_acc.id, is_active=True).exists())

        # 2. Create a secondary account with balance > 0
        extra_acc = FinancialAccount.objects.create(
            workspace=self.workspace,
            name="Emergency Cash",
            account_type=FinancialAccount.ACCOUNT_TYPE_CASH,
            opening_balance=Decimal('500.00'),
            current_balance=Decimal('500.00'),
            is_active=True,
        )
        # Try to delete account holding money -> Blocked
        resp_money = self.client.post(reverse('account_delete', args=[extra_acc.id]), follow=True)
        self.assertEqual(resp_money.status_code, 200)
        self.assertContains(resp_money, "holds an active balance")
        self.assertTrue(FinancialAccount.objects.filter(id=extra_acc.id, is_active=True).exists())

        # 3. Create account with 0 balance and 0 transactions -> Permanent delete succeeds
        empty_acc = FinancialAccount.objects.create(
            workspace=self.workspace,
            name="Temporary Account",
            account_type=FinancialAccount.ACCOUNT_TYPE_UPI,
            opening_balance=Decimal('0.00'),
            current_balance=Decimal('0.00'),
            is_active=True,
        )
        resp_empty = self.client.post(reverse('account_delete', args=[empty_acc.id]), follow=True)
        self.assertEqual(resp_empty.status_code, 200)
        self.assertContains(resp_empty, "deleted permanently")
        self.assertFalse(FinancialAccount.objects.filter(id=empty_acc.id).exists())

        # 4. Zero out extra_acc by withdrawing, then delete -> Since it has transactions, it is archived
        extra_acc.withdraw(
            amount=Decimal('500.00'),
            description="Clear balance for closure",
            user=self.user,
        )
        extra_acc.refresh_from_db()
        self.assertEqual(extra_acc.current_balance, Decimal('0.00'))

        resp_archive = self.client.post(reverse('account_delete', args=[extra_acc.id]), follow=True)
        self.assertEqual(resp_archive.status_code, 200)
        self.assertContains(resp_archive, "safely archived")
        extra_acc.refresh_from_db()
        self.assertFalse(extra_acc.is_active)

        # 5. Reactivate the archived account
        resp_reactivate = self.client.post(reverse('account_reactivate', args=[extra_acc.id]), follow=True)
        self.assertEqual(resp_reactivate.status_code, 200)
        self.assertContains(resp_reactivate, "has been reactivated")
        extra_acc.refresh_from_db()
        self.assertTrue(extra_acc.is_active)

    def test_explicit_account_deactivate_and_edit_status_workflow(self):
        from job_tickets.access_control import apply_staff_access
        apply_staff_access(self.user, ["company_settings"])
        self.client.login(username="accounts_staff", password="password123")

        # 1. Create a secondary savings bank account
        savings = FinancialAccount.objects.create(
            workspace=self.workspace,
            name="Secondary Savings",
            account_type=FinancialAccount.ACCOUNT_TYPE_BANK,
            bank_name="HDFC Bank",
            account_number="501002345678",
            opening_balance=Decimal('0.00'),
            current_balance=Decimal('0.00'),
            is_active=True,
        )

        # 2. Check UI has the explicit "Deactivate" button
        url = reverse('company_profile_settings') + '?tab=bank-details'
        resp_ui = self.client.get(url)
        self.assertEqual(resp_ui.status_code, 200)
        self.assertContains(resp_ui, 'Deactivate')
        self.assertContains(resp_ui, f'deactivate-account-form-{savings.id}')

        # 3. Call account_deactivate directly
        resp_deact = self.client.post(reverse('account_deactivate', args=[savings.id]), follow=True)
        self.assertEqual(resp_deact.status_code, 200)
        self.assertContains(resp_deact, "has been deactivated and moved to archived accounts")
        savings.refresh_from_db()
        self.assertFalse(savings.is_active)

        # 4. In UI, check that it appears in Archived Accounts with Reactivate button
        resp_arch_ui = self.client.get(url)
        self.assertContains(resp_arch_ui, 'Archived / Deactivated Accounts')
        self.assertContains(resp_arch_ui, 'Secondary Savings')
        self.assertContains(resp_arch_ui, f'reactivate-account-form-{savings.id}')

        # 5. Reactivate via account_reactivate
        resp_react = self.client.post(reverse('account_reactivate', args=[savings.id]), follow=True)
        self.assertEqual(resp_react.status_code, 200)
        savings.refresh_from_db()
        self.assertTrue(savings.is_active)

        # 6. Test editing account and deactivating via editAccountModal (status_submitted without is_active)
        resp_edit_deact = self.client.post(
            reverse('account_edit', args=[savings.id]),
            data={
                'name': 'Secondary Savings Updated',
                'account_type': 'bank',
                'bank_name': 'HDFC Bank',
                'account_number': '501002345678',
                'status_submitted': '1',
                # 'is_active' omitted to represent unchecking the switch
            },
            follow=True
        )
        self.assertEqual(resp_edit_deact.status_code, 200)
        savings.refresh_from_db()
        self.assertEqual(savings.name, 'Secondary Savings Updated')
        self.assertFalse(savings.is_active)

        # 7. Reactivate via editAccountModal (status_submitted with is_active='true')
        resp_edit_act = self.client.post(
            reverse('account_edit', args=[savings.id]),
            data={
                'name': 'Secondary Savings Updated',
                'account_type': 'bank',
                'bank_name': 'HDFC Bank',
                'account_number': '501002345678',
                'status_submitted': '1',
                'is_active': 'true',
            },
            follow=True
        )
        self.assertEqual(resp_edit_act.status_code, 200)
        savings.refresh_from_db()
        self.assertTrue(savings.is_active)

    def test_accounts_dashboard_view_renders_successfully(self):
        self.client.force_login(self.user)
        response = self.client.get(reverse('accounts_dashboard'))
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Financial Accounts &amp; Cash Drawers')
        self.assertContains(response, 'Total Liquid Capital')
        self.assertContains(response, self.cash_acc.name)
        self.assertContains(response, self.bank_acc.name)

    def test_staff_dashboard_does_not_contain_accounts_banner_or_transfer_modal(self):
        self.client.force_login(self.user)
        response = self.client.get(reverse('staff_dashboard'))
        self.assertEqual(response.status_code, 200)
        self.assertNotContains(response, 'Accounts &amp; Cash Drawer')
        self.assertNotContains(response, 'staffDashboardTransferModal')

    def test_account_management_permission_control(self):
        # 1. User with ONLY account_management + staff_dashboard
        staff_acct = User.objects.create_user(
            username="acct_only_user",
            password="password123",
            is_staff=True,
        )
        CompanyUserMembership.objects.create(
            workspace=self.workspace,
            user=staff_acct,
            role=CompanyUserMembership.ROLE_STAFF,
            is_active=True,
        )
        apply_staff_access(staff_acct, {"account_management", "staff_dashboard"})

        self.client.force_login(staff_acct)

        # Can view accounts_dashboard, and duplicate auto-page-title is suppressed
        resp_acct = self.client.get(reverse('accounts_dashboard'))
        self.assertEqual(resp_acct.status_code, 200)
        self.assertNotContains(resp_acct, 'class="section-title mb-0"')
        self.assertContains(resp_acct, 'Financial Accounts &amp; Cash Drawers')

        # Staff dashboard does NOT display accounts widget
        resp_dash = self.client.get(reverse('staff_dashboard'))
        self.assertEqual(resp_dash.status_code, 200)
        self.assertNotContains(resp_dash, 'Accounts &amp; Cash Drawer')

        # CANNOT view company profile settings (must be blocked)
        resp_settings = self.client.get(reverse('company_profile_settings'))
        self.assertNotEqual(resp_settings.status_code, 200)
        self.assertEqual(resp_settings.status_code, 302)

        # 2. User WITHOUT account_management (only staff_dashboard)
        staff_no_acct = User.objects.create_user(
            username="no_acct_user",
            password="password123",
            is_staff=True,
        )
        CompanyUserMembership.objects.create(
            workspace=self.workspace,
            user=staff_no_acct,
            role=CompanyUserMembership.ROLE_STAFF,
            is_active=True,
        )
        apply_staff_access(staff_no_acct, {"staff_dashboard"})

        self.client.force_login(staff_no_acct)

        # CANNOT view accounts_dashboard
        resp_no_acct = self.client.get(reverse('accounts_dashboard'))
        self.assertNotEqual(resp_no_acct.status_code, 200)
        self.assertEqual(resp_no_acct.status_code, 302)

        # Can view staff dashboard, and accounts widget is not present
        resp_dash_no = self.client.get(reverse('staff_dashboard'))
        self.assertEqual(resp_dash_no.status_code, 200)
        self.assertNotContains(resp_dash_no, 'Accounts &amp; Cash Drawer')
        self.assertNotContains(resp_dash_no, 'staffDashboardTransferModal')



