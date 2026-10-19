from datetime import timedelta
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth.models import Group, User
from django.http import HttpResponse, Http404
from django.test import RequestFactory, TestCase
from django.urls import reverse
from django.utils import timezone

from .models import (
    CompanyWorkspace, JobTicket, JobTicketLog, ServiceLog,
    SpecializedService, TechnicianProfile, Vendor,
)
from .views import report_views
from .views import staff_views
from .access_control import apply_staff_access
from .views.helpers import get_jobs_for_report_period, get_report_period, report_date_bounds
from .views.vendor_views import _build_vendor_report_context


class ReportConsistencyTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.admin = User.objects.create_user('report-review-admin', is_staff=True, is_superuser=True)
        cls.workspace = CompanyWorkspace.objects.create(name='Report workspace', owner=cls.admin)
        cls.other_workspace = CompanyWorkspace.objects.create(name='Other workspace', owner=cls.admin)
        tech_user = User.objects.create_user('report-review-tech')
        tech_user.groups.add(Group.objects.get_or_create(name='Technicians')[0])
        cls.technician = TechnicianProfile.objects.create(
            workspace=cls.workspace, user=tech_user, unique_id='RPT001',
        )

    def setUp(self):
        self.today = timezone.localdate()
        self.start, self.end = report_date_bounds(self.today, self.today)
        self.factory = RequestFactory()

    def request(self, **params):
        request = self.factory.get('/staff/reports/', params)
        request.user = self.admin
        request.current_workspace = self.workspace
        return request

    def job(self, code, status='Completed', workspace=None, **kwargs):
        return JobTicket.objects.create(
            job_code=code, workspace=workspace or self.workspace,
            customer_name='Report customer', customer_phone='9876543210',
            device_type='Laptop', reported_issue='Repair', status=status,
            assigned_to=self.technician, **kwargs,
        )

    def transition(self, job, status, timestamp):
        log = JobTicketLog.objects.create(
            job_ticket=job, action='CLOSED' if status == 'Closed' else 'STATUS',
            details=f"Status changed from 'Repairing' to '{status}'.",
        )
        JobTicketLog.objects.filter(pk=log.pk).update(timestamp=timestamp)

    def context(self, view, request=None, *args):
        with patch('job_tickets.views.report_views.render', return_value=HttpResponse('ok')) as render:
            response = view(request or self.request(), *args)
        self.assertEqual(response.status_code, 200)
        return render.call_args.args[2]

    def test_old_job_closed_today_is_in_card_and_detail(self):
        job = self.job('REPORT-OLD-CLOSED', status='Closed', discount_amount=Decimal('20'))
        JobTicket.objects.filter(pk=job.pk).update(created_at=self.start - timedelta(days=20))
        self.transition(job, 'Closed', self.start + timedelta(hours=10))
        ServiceLog.objects.create(job_ticket=job, description='Repair', part_cost=100, service_charge=50)
        dashboard = self.context(report_views.reports_dashboard)
        detail = self.context(report_views.daily_jobs_report, self.request(), self.today.isoformat(), 'out')
        self.assertEqual(dashboard['todays_jobs_out'], 1)
        self.assertEqual([row.pk for row in detail['jobs']], [job.pk])
        self.assertEqual(dashboard['todays_closed_total'], detail['jobs'][0].net_total)
        self.assertEqual(dashboard['todays_closed_total'], Decimal('130'))

    def test_completion_survives_pickup_and_close_and_is_not_duplicated(self):
        job = self.job('REPORT-COMPLETE-CLOSED', status='Closed')
        self.transition(job, 'Completed', self.start + timedelta(hours=9))
        self.transition(job, 'Completed', self.start + timedelta(hours=10))
        self.transition(job, 'Closed', self.start + timedelta(hours=11))
        dashboard = self.context(report_views.reports_dashboard)
        detail = self.context(report_views.daily_jobs_report, self.request(), self.today.isoformat(), 'completed')
        self.assertEqual(dashboard['todays_jobs_completed'], 1)
        self.assertEqual([row.pk for row in detail['jobs']], [job.pk])

    def test_editing_old_completion_does_not_make_it_completed_today(self):
        job = self.job('REPORT-OLD-COMPLETED')
        self.transition(job, 'Completed', self.start - timedelta(days=10))
        JobTicket.objects.filter(pk=job.pk).update(updated_at=self.start + timedelta(hours=10))
        dashboard = self.context(report_views.reports_dashboard)
        detail = self.context(report_views.daily_jobs_report, self.request(), self.today.isoformat(), 'completed')
        self.assertEqual(dashboard['todays_jobs_completed'], 0)
        self.assertEqual(detail['jobs'], [])
        self.assertEqual(get_jobs_for_report_period(self.start, self.end, workspace=self.workspace), [])
        previous = get_jobs_for_report_period(self.start - timedelta(days=10), self.start - timedelta(days=9), workspace=self.workspace)
        self.assertEqual([row.pk for row in previous], [job.pk])

    def test_daily_details_and_returned_count_are_workspace_scoped(self):
        foreign = self.job('REPORT-FOREIGN', 'Closed', workspace=self.other_workspace)
        log = JobTicketLog.objects.create(job_ticket=foreign, action='CLOSED', details="Status changed from 'Returned' to 'Closed'.")
        JobTicketLog.objects.filter(pk=log.pk).update(timestamp=self.start + timedelta(hours=10))
        self.transition(foreign, 'Completed', self.start + timedelta(hours=9))
        for kind in ('in', 'out', 'completed'):
            detail = self.context(report_views.daily_jobs_report, self.request(), self.today.isoformat(), kind)
            self.assertEqual(detail['jobs'], [])
        self.assertEqual(self.context(report_views.reports_dashboard)['returned_count'], 0)

    def test_ready_for_pickup_badge_adds_both_statuses(self):
        self.job('REPORT-COMPLETED')
        self.job('REPORT-READY', 'Ready for Pickup')
        self.assertEqual(self.context(report_views.reports_dashboard)['completed_awaiting_billing_count'], 2)

    def test_closed_job_keeps_audited_date_after_edit_or_backfill(self):
        job = self.job('REPORT-CLOSED-DATE', 'Closed', closed_at=self.start)
        event_time = self.start - timedelta(days=10)
        self.transition(job, 'Closed', event_time)
        self.assertEqual(get_jobs_for_report_period(self.start, self.end, workspace=self.workspace), [])
        rows = get_jobs_for_report_period(event_time, event_time + timedelta(days=1), workspace=self.workspace)
        self.assertEqual([row.pk for row in rows], [job.pk])
        self.assertEqual(rows[0].report_date, event_time)

    def test_technician_dashboard_print_and_csv_share_vendor_return_date(self):
        job = self.job('REPORT-TECH-VENDOR')
        vendor = Vendor.objects.create(workspace=self.workspace, name='Vendor', company_name='Vendor report')
        SpecializedService.objects.create(
            job_ticket=job, vendor=vendor, status='Returned',
            returned_date=self.start + timedelta(hours=12),
        )
        JobTicket.objects.filter(pk=job.pk).update(updated_at=self.start - timedelta(days=20))
        ServiceLog.objects.create(job_ticket=job, description='Repair', part_cost=100, service_charge=50)
        params = {'start_date': self.today.isoformat(), 'end_date': self.today.isoformat()}
        dashboard = self.context(report_views.reports_dashboard, self.request(**params))
        detail = report_views._build_technician_report_context(self.request(**params), self.technician.pk)
        row = dashboard['monthly_tech_performance'][0]
        self.assertEqual(row.jobs_done, detail['jobs_count'])
        self.assertEqual(row.jobs_done, 1)
        self.assertEqual(row.monthly_parts_sales, detail['total_parts'])
        self.assertEqual(row.monthly_service_sales, detail['total_services'])
        self.assertEqual(row.monthly_total_sales, Decimal('150.00'))
        self.assertEqual(dashboard['tech_total_jobs'], 1)
        self.assertEqual(dashboard['tech_total_parts_sales'], Decimal('100.00'))
        self.assertEqual(dashboard['tech_total_service_sales'], Decimal('50.00'))
        self.assertEqual(dashboard['tech_total_combined_sales'], Decimal('150.00'))
        response = report_views.technician_report_export_csv(self.request(**params), self.technician.pk)
        self.assertIn(job.job_code, response.content.decode())

    def test_technician_performance_counts_completed_in_month_and_links_full_report(self):
        # Job 1: completed today -> should count today
        job1 = self.job('REPORT-TECH-COMP-TODAY', 'Completed')
        self.transition(job1, 'Completed', self.start + timedelta(hours=2))
        ServiceLog.objects.create(job_ticket=job1, description='Screen', part_cost=200, service_charge=100)

        # Job 2: completed 10 days ago (prior period), closed today -> should NOT count in today's performance
        job2 = self.job('REPORT-TECH-PREV-COMP', 'Closed')
        self.transition(job2, 'Completed', self.start - timedelta(days=10))
        self.transition(job2, 'Closed', self.start + timedelta(hours=4))
        ServiceLog.objects.create(job_ticket=job2, description='Battery', part_cost=50, service_charge=50)

        params = {'start_date': self.today.isoformat(), 'end_date': self.today.isoformat(), 'tab': 'technician'}
        dashboard = self.context(report_views.reports_dashboard, self.request(**params))
        row = dashboard['monthly_tech_performance'][0]

        # Only job1 was completed in this period
        self.assertEqual(row.jobs_done, 1)
        self.assertEqual(row.monthly_parts_sales, Decimal('200.00'))
        self.assertEqual(row.monthly_service_sales, Decimal('100.00'))
        self.assertEqual(dashboard['tech_total_jobs'], 1)

    def test_foreign_technician_report_returns_404(self):
        user = User.objects.create_user('foreign-report-tech')
        tech = TechnicianProfile.objects.create(user=user, workspace=self.other_workspace, unique_id='RPT002')
        with self.assertRaises(Http404):
            report_views._build_technician_report_context(self.request(), tech.pk)

    def test_vendor_dashboard_and_detail_include_returned_unclosed_jobs(self):
        vendor = Vendor.objects.create(workspace=self.workspace, name='Vendor', company_name='Returned vendor')
        job = self.job('REPORT-VENDOR-READY', 'Ready for Pickup')
        SpecializedService.objects.create(
            job_ticket=job, vendor=vendor, status='Returned',
            returned_date=self.end - timedelta(microseconds=1), vendor_cost=100, client_charge=150,
        )
        params = {'start_date': self.today.isoformat(), 'end_date': self.today.isoformat()}
        dashboard = self.context(report_views.reports_dashboard, self.request(**params))
        detail = _build_vendor_report_context(self.request(**params), vendor.pk)
        row = list(dashboard['vendor_performance'])[0]
        self.assertEqual(row.total_jobs_given, 1)
        self.assertEqual(row.total_jobs_given, detail['total_jobs'])
        self.assertEqual(row.total_vendor_cost, detail['total_vendor_cost'])
        self.assertEqual(row.total_client_charge, detail['total_client_charge'])
        self.assertEqual(dashboard['vendor_total_jobs'], 1)
        self.assertEqual(dashboard['vendor_total_cost'], Decimal('100.00'))
        self.assertEqual(dashboard['vendor_total_client_charge'], Decimal('150.00'))
        self.assertEqual(dashboard['vendor_total_profit'], Decimal('50.00'))

    def test_period_includes_last_fractional_second_but_not_next_day(self):
        first = self.job('REPORT-LAST-SECOND')
        second = self.job('REPORT-NEXT-DAY')
        self.transition(first, 'Completed', self.end - timedelta(microseconds=1))
        self.transition(second, 'Completed', self.end)
        period = get_report_period(self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat()))
        jobs = get_jobs_for_report_period(period['start'], period['end'], workspace=self.workspace)
        self.assertEqual([job.pk for job in jobs], [first.pk])

    def test_reversed_period_is_normalized(self):
        earlier = self.today - timedelta(days=3)
        period = get_report_period(self.request(start_date=self.today.isoformat(), end_date=earlier.isoformat()))
        self.assertEqual(period['start_date_str'], earlier.isoformat())
        self.assertEqual(period['end_date_str'], self.today.isoformat())

    def test_chart_buckets_do_not_include_jobs_outside_selected_days(self):
        inside = self.job('REPORT-CHART-IN')
        outside = self.job('REPORT-CHART-OUT')
        self.transition(inside, 'Completed', self.start + timedelta(hours=10))
        self.transition(outside, 'Completed', self.end + timedelta(hours=10))
        response = report_views.reports_chart_data(self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat()))
        import json
        payload = json.loads(response.content)
        self.assertEqual(payload['monthly'][0]['jobs_finished'], 1)
        self.assertEqual(payload['yearly'][0]['jobs_finished'], 1)

    def test_dashboard_tabs_render_with_shared_period_and_financial_exports(self):
        self.client.force_login(self.admin)
        for tab, heading in [('overview', "Today's activity"), ('financial', 'Financial Summary'),
                             ('technician', 'Technician performance'), ('vendor', 'Vendor performance')]:
            response = self.client.get(reverse('reports_dashboard'), {
                'tab': tab, 'start_date': self.today.isoformat(), 'end_date': self.today.isoformat(),
            })
            self.assertContains(response, heading)
            self.assertContains(response, f'name="tab" value="{tab}"')
        self.assertNotContains(response, 'chart.js')

    def test_financial_tab_matches_printed_summary_after_old_job_edit(self):
        job = self.job('REPORT-FINANCIAL', 'Closed', closed_at=self.start - timedelta(days=10))
        self.transition(job, 'Closed', self.start + timedelta(hours=10))
        ServiceLog.objects.create(job_ticket=job, description='Repair', part_cost=100, service_charge=50)
        request = self.request(tab='financial', start_date=self.today.isoformat(), end_date=self.today.isoformat())
        dashboard = self.context(report_views.reports_dashboard, request)
        printed = self.context(report_views.print_monthly_summary_report, request)
        for key in ('overall_revenue', 'overall_expense', 'overall_profit', 'jobs_closed_count'):
            self.assertEqual(dashboard['financial_summary'][key], printed[key])
        self.assertEqual(printed['jobs_closed_count'], 1)
        self.assertEqual(printed['overall_revenue'], Decimal('150'))

    def test_archive_drilldowns_are_workspace_scoped(self):
        local = self.job('REPORT-ARCHIVE-LOCAL', 'Ready for Pickup')
        self.job('REPORT-ARCHIVE-FOREIGN', 'Ready for Pickup', workspace=self.other_workspace)
        for view, args in [(staff_views.staff_job_archive_view, ()),
                           (staff_views.staff_job_filtered_archive_view, ('CompletedReady',))]:
            response = view(self.request(), *args)
            self.assertContains(response, local.job_code)
            self.assertNotContains(response, 'REPORT-ARCHIVE-FOREIGN')

    def test_financial_tab_is_hidden_without_financial_section_access(self):
        user = User.objects.create_user('reports-overview-only', is_staff=True)
        apply_staff_access(user, {'reports_dashboard'})
        request = self.request(tab='financial')
        request.user = user
        response = report_views.reports_dashboard(request)
        self.assertContains(response, "Today's activity")
        self.assertNotContains(response, 'Revenue after discounts')
        self.assertNotContains(response, 'Export CSV')

    def test_monthly_closed_and_ready_breakdown(self):
        closed_job = self.job('REPORT-MONTHLY-CLOSED', status='Closed')
        self.transition(closed_job, 'Closed', self.start + timedelta(hours=5))
        ServiceLog.objects.create(job_ticket=closed_job, description='Screen', part_cost=1000, service_charge=500)

        ready_job = self.job('REPORT-MONTHLY-READY', status='Ready for Pickup')
        self.transition(ready_job, 'Ready for Pickup', self.start + timedelta(hours=6))
        ServiceLog.objects.create(job_ticket=ready_job, description='Battery', part_cost=500, service_charge=200)

        breakdown, totals = report_views.get_monthly_closed_and_ready_breakdown(self.workspace)
        self.assertGreaterEqual(len(breakdown), 1)
        current_m = self.today.strftime('%Y-%m')
        match = next((b for b in breakdown if b['month_key'] == current_m), None)
        self.assertIsNotNone(match)
        self.assertGreaterEqual(match['closed_count'], 1)
        self.assertGreaterEqual(match['closed_value'], Decimal('1500.00'))
        self.assertGreaterEqual(match['ready_count'], 1)
        self.assertGreaterEqual(match['ready_value'], Decimal('700.00'))
        self.assertEqual(match['combined_value'], match['closed_value'] + match['ready_value'])
        self.assertEqual(totals['combined_value'], totals['closed_value'] + totals['ready_value'])

    def test_technician_report_monthly_breakdown(self):
        tech_user2 = User.objects.create_user('report-other-tech')
        other_technician = TechnicianProfile.objects.create(
            workspace=self.workspace, user=tech_user2, unique_id='RPT002',
        )

        my_job = self.job('TECH1-JOB-CLOSED', status='Closed')
        self.transition(my_job, 'Closed', self.start + timedelta(hours=2))
        ServiceLog.objects.create(job_ticket=my_job, description='Speaker', part_cost=200, service_charge=300)

        other_job = JobTicket.objects.create(
            job_code='TECH2-JOB-CLOSED', workspace=self.workspace,
            customer_name='Other Customer', customer_phone='9876543211',
            status='Closed', assigned_to=other_technician,
        )
        self.transition(other_job, 'Closed', self.start + timedelta(hours=3))
        ServiceLog.objects.create(job_ticket=other_job, description='Battery', part_cost=800, service_charge=400)

        my_breakdown, my_totals = report_views.get_monthly_closed_and_ready_breakdown(
            self.workspace, technician=self.technician,
        )
        current_m = self.today.strftime('%Y-%m')
        my_row = next((b for b in my_breakdown if b['month_key'] == current_m), None)
        self.assertIsNotNone(my_row)
        self.assertEqual(my_row['closed_value'], Decimal('500.00'))
        self.assertEqual(my_row['closed_count'], 1)

        req = self.request()
        ctx = report_views._build_technician_report_context(req, self.technician.id)
        self.assertIn('monthly_breakdown', ctx)
        self.assertIn('monthly_breakdown_totals', ctx)

        from django.template.loader import render_to_string
        rendered = render_to_string(
            'job_tickets/technician_report_print.html',
            ctx,
            request=req,
        )
        self.assertIn('id="jobs-tab"', rendered)
        self.assertIn('id="monthly-tab"', rendered)
        self.assertIn('id="tab-jobs"', rendered)
        self.assertIn('id="tab-monthly"', rendered)
        self.assertIn('Monthly Revenue, Service Charges &amp; Parts Breakdown', rendered)

    def test_technician_report_status_filtering_and_counts(self):
        from django.template.loader import render_to_string

        ready_job = self.job('TECH-READY-001', status='Ready for Pickup')
        self.transition(ready_job, 'Ready for Pickup', self.start + timedelta(hours=2))
        ServiceLog.objects.create(job_ticket=ready_job, description='Screen replacement', part_cost=500, service_charge=300)

        closed_job = self.job('TECH-CLOSED-001', status='Closed')
        self.transition(closed_job, 'Closed', self.start + timedelta(hours=3))
        ServiceLog.objects.create(job_ticket=closed_job, description='Battery replacement', part_cost=200, service_charge=150)

        # 1. All (default)
        req_all = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat(), status='all')
        ctx_all = report_views._build_technician_report_context(req_all, self.technician.id)
        job_codes_all = [j.job_code for j in ctx_all['jobs']]
        self.assertIn('TECH-READY-001', job_codes_all)
        self.assertIn('TECH-CLOSED-001', job_codes_all)
        self.assertEqual(ctx_all['ready_count'], 1)
        self.assertEqual(ctx_all['closed_count'], 1)
        self.assertEqual(ctx_all['jobs_count'], 2)
        rendered_all = render_to_string('job_tickets/technician_report_print.html', ctx_all, request=req_all)
        self.assertIn('name="status"', rendered_all)
        self.assertIn('value="Ready for Pickup"', rendered_all)
        self.assertIn('value="Closed"', rendered_all)

        # 2. Filter: Ready for Pickup
        req_ready = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat(), status='Ready for Pickup')
        ctx_ready = report_views._build_technician_report_context(req_ready, self.technician.id)
        job_codes_ready = [j.job_code for j in ctx_ready['jobs']]
        self.assertEqual(job_codes_ready, ['TECH-READY-001'])
        self.assertEqual(ctx_ready['ready_count'], 1)
        self.assertEqual(ctx_ready['closed_count'], 0)
        self.assertEqual(ctx_ready['selected_status'], 'Ready for Pickup')
        rendered_ready = render_to_string('job_tickets/technician_report_print.html', ctx_ready, request=req_ready)
        self.assertIn('(1 ready for pickup)', rendered_ready)
        self.assertIn('Status: <span class="badge bg-secondary">Ready for Pickup</span>', rendered_ready)

        # 3. Filter: Closed
        req_closed = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat(), status='Closed')
        ctx_closed = report_views._build_technician_report_context(req_closed, self.technician.id)
        job_codes_closed = [j.job_code for j in ctx_closed['jobs']]
        self.assertEqual(job_codes_closed, ['TECH-CLOSED-001'])
        self.assertEqual(ctx_closed['ready_count'], 0)
        self.assertEqual(ctx_closed['closed_count'], 1)
        self.assertEqual(ctx_closed['selected_status'], 'Closed')
        rendered_closed = render_to_string('job_tickets/technician_report_print.html', ctx_closed, request=req_closed)
        self.assertIn('(1 closed)', rendered_closed)

        # 4. CSV Export with Status Filter
        res_csv = report_views.technician_report_export_csv(req_ready, self.technician.id)
        content = res_csv.content.decode('utf-8')
        self.assertIn('Ready for Pickup', content)
        self.assertIn('TECH-READY-001', content)
        self.assertNotIn('TECH-CLOSED-001', content)

    def test_financial_summary_monthly_breakdown_with_credit_bills(self):
        from .models import InventoryParty, InventoryBill, InventoryCreditPayment

        closed_job = self.job('REPORT-FIN-BREAKDOWN-CLOSED', status='Closed')
        self.transition(closed_job, 'Closed', self.start + timedelta(hours=1))
        ServiceLog.objects.create(job_ticket=closed_job, description='Motherboard', part_cost=2000, service_charge=1000)

        party = InventoryParty.objects.create(workspace=self.workspace, name='Fin Cust', party_type='customer')
        bill = InventoryBill.objects.create(
            workspace=self.workspace,
            bill_number='SB-FIN-001',
            entry_type='sale',
            entry_date=self.today,
            party=party,
            job_ticket=closed_job,
        )
        InventoryCreditPayment.objects.create(
            workspace=self.workspace,
            party=party,
            bill=bill,
            amount=Decimal('1000.00'),
            direction=InventoryCreditPayment.DIRECTION_RECEIVABLE,
            payment_date=self.today,
        )

        ready_job = self.job('REPORT-FIN-BREAKDOWN-READY', status='Ready for Pickup')
        self.transition(ready_job, 'Ready for Pickup', self.start + timedelta(hours=2))
        ServiceLog.objects.create(job_ticket=ready_job, description='Screen', part_cost=500, service_charge=300)

        breakdown, totals = report_views.get_monthly_closed_and_ready_breakdown(self.workspace)
        current_m = self.today.strftime('%Y-%m')
        row = next((b for b in breakdown if b['month_key'] == current_m), None)
        self.assertIsNotNone(row)
        self.assertEqual(row['closed_count'], 1)
        self.assertEqual(row['credit_bills'], Decimal('3000.00'))
        self.assertEqual(row['outstanding_balance'], Decimal('2000.00'))
        self.assertEqual(row['ready_count'], 1)
        self.assertEqual(row['ready_value'], Decimal('800.00'))

        # Check printable monthly summary report context and rendering
        req = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat())
        req.user = self.admin
        req.current_workspace = self.workspace
        resp = report_views.print_monthly_summary_report(req)
        self.assertEqual(resp.status_code, 200)
        content = resp.content.decode()
        self.assertIn('Monthly Closed &amp; Ready for Pickup Breakdown', content)
        self.assertIn('Closed Jobs', content)
        self.assertIn('Credit Bills', content)
        self.assertIn('Outstanding Balance', content)
        self.assertIn('Ready for Pickup Jobs', content)
        self.assertIn('Ready for Pickup Value', content)
        self.assertIn('monthlyYearFilterGroup', content)
        self.assertIn('All Time', content)
        self.assertIn(str(self.today.year), content)
        self.assertIn('monthly-data-row', content)
        self.assertNotIn('Closed Value', content)
        self.assertNotIn('Ready for Pickup Receivables', content)

    def test_financial_summary_monthly_breakdown_year_filter(self):
        closed_job = self.job('REPORT-FIN-YEAR-FILTER-01', status='Closed')
        self.transition(closed_job, 'Closed', self.start)
        ServiceLog.objects.create(job_ticket=closed_job, description='Motherboard', part_cost=1000, service_charge=500)

        current_year = str(self.today.year)

        # 1. Default All Time
        req = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat())
        req.user = self.admin
        req.current_workspace = self.workspace
        resp = report_views.print_monthly_summary_report(req)
        self.assertEqual(resp.status_code, 200)
        content = resp.content.decode()
        self.assertIn('All Time', content)
        self.assertIn(current_year, content)
        self.assertIn(f'"years": ["{current_year}"]', content)

        # 2. Year-wise query parameter
        req_yr = self.request(start_date=self.today.isoformat(), end_date=self.today.isoformat(), breakdown_year=current_year)
        req_yr.user = self.admin
        req_yr.current_workspace = self.workspace
        resp_yr = report_views.print_monthly_summary_report(req_yr)
        self.assertEqual(resp_yr.status_code, 200)
        content_yr = resp_yr.content.decode()
        self.assertIn(f'data-year="{current_year}"', content_yr)

    def test_reports_dashboard_no_longer_renders_monthly_breakdown(self):
        req = self.request(tab='financial', start_date=self.today.isoformat(), end_date=self.today.isoformat())
        req.user = self.admin
        req.current_workspace = self.workspace
        resp = report_views.reports_dashboard(req)
        self.assertEqual(resp.status_code, 200)
        content = resp.content.decode()
        self.assertNotIn('Monthly Closed &amp; Ready for Pickup Breakdown', content)

    def test_technician_performance_stock_sales_and_info_buttons(self):
        from .models import Product, InventoryParty, InventoryBill, InventoryEntry

        # Create a direct over-the-counter stock sale by technician's user
        tech_user = self.technician.user
        party = InventoryParty.objects.create(
            workspace=self.workspace,
            name='Walk-in Retail Buyer',
            party_type='customer',
        )
        product = Product.objects.create(
            workspace=self.workspace,
            name='USB Cable Type-C',
            sku='CAB-TYPEC-01',
            cost_price=Decimal('50.00'),
            unit_price=Decimal('150.00'),
        )
        bill = InventoryBill.objects.create(
            workspace=self.workspace,
            bill_number='BILL-STOCK-TEST-001',
            entry_type='sale',
            entry_date=self.today,
            party=party,
            created_by=tech_user,
        )
        InventoryEntry.objects.create(
            workspace=self.workspace,
            bill=bill,
            entry_number='ENT-STOCK-TEST-001',
            entry_type='sale',
            entry_date=self.today,
            party=party,
            product=product,
            quantity=3,
            unit_price=Decimal('150.00'),
            taxable_amount=Decimal('450.00'),
            total_amount=Decimal('450.00'),
            created_by=tech_user,
        )

        # 1. Test reports_dashboard technician tab
        req = self.request(tab='technician', start_date=self.today.isoformat(), end_date=self.today.isoformat())
        ctx = self.context(report_views.reports_dashboard, req)
        tech_perf = [tp for tp in ctx['monthly_tech_performance'] if tp.id == self.technician.id]
        self.assertEqual(len(tech_perf), 1)
        self.assertEqual(tech_perf[0].monthly_stock_sales, Decimal('450.00'))
        self.assertEqual(ctx['tech_total_stock_sales'], Decimal('450.00'))

        res = report_views.reports_dashboard(req)
        self.assertEqual(res.status_code, 200)
        html = res.content.decode('utf-8')

        # Check stock sales table headers and explanatory info tooltips
        self.assertIn('Parts Sales', html)
        self.assertIn('Stock Sales', html)
        self.assertIn('About Parts Sales', html)
        self.assertIn('About Stock Sales', html)
        self.assertIn('data-bs-toggle="tooltip"', html)
        self.assertIn('450.00', html)

        # 2. Test staff_technician_reports
        req2 = self.factory.get('/staff/technicians/reports/')
        req2.user = self.admin
        req2.current_workspace = self.workspace
        ctx2 = self.context(report_views.staff_technician_reports, req2)
        row = next(r for r in ctx2['tech_rows'] if r['tech'].id == self.technician.id)
        self.assertEqual(row['stock_total'], Decimal('450.00'))

        res2 = report_views.staff_technician_reports(req2)
        self.assertEqual(res2.status_code, 200)
        html2 = res2.content.decode('utf-8')
        self.assertIn('Stock Sales', html2)
        self.assertIn('About Parts Total', html2)
        self.assertIn('About Stock Sales', html2)
        self.assertIn('450.00', html2)

        # 3. Test technician_report_print view & context
        req3 = self.factory.get(f'/reports/technician/{self.technician.id}/print/')
        req3.user = self.admin
        req3.current_workspace = self.workspace
        ctx3 = report_views._build_technician_report_context(req3, self.technician.id)
        self.assertEqual(len(ctx3['stock_sales']), 1)
        self.assertEqual(ctx3['total_stock_sales_amount'], Decimal('450.00'))
        self.assertEqual(ctx3['total_stock_profit'], Decimal('300.00'))
        self.assertIn('stock_sales', ctx3['monthly_chart_json'])

        res3 = report_views.technician_report_print(req3, self.technician.id)
        self.assertEqual(res3.status_code, 200)
        html3 = res3.content.decode('utf-8')
        self.assertIn('tab-stock', html3)
        self.assertIn('BILL-STOCK-TEST-001', html3)
        self.assertIn('USB Cable Type-C', html3)
        self.assertIn('About Stock Sales', html3)
        self.assertIn('About Part Cost', html3)
        self.assertIn('About Service Charge', html3)
        self.assertIn('data-chart-mode="stock"', html3)

        # 4. Test technician_report_export_csv
        res4 = report_views.technician_report_export_csv(req3, self.technician.id)
        self.assertEqual(res4.status_code, 200)
        csv_content = res4.content.decode('utf-8')
        self.assertIn('Direct Stock Sales', csv_content)
        self.assertIn('Total Service Charges', csv_content)
        self.assertIn('Total Combined Revenue (Jobs + Stock),450.00', csv_content)
        self.assertIn('Total Combined Profit (Jobs + Stock),300.00', csv_content)
        self.assertIn('BILL-STOCK-TEST-001', csv_content)
        self.assertIn('USB Cable Type-C', csv_content)
        self.assertIn('450.00', csv_content)



class InventoryDashboardAndCreditTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('inv-test-admin', is_staff=True, is_superuser=True)
        self.workspace = CompanyWorkspace.objects.create(name='Inv Test Workspace', owner=self.user)
        self.factory = RequestFactory()

    def test_dashboard_metrics_stock_units_and_profit(self):
        from .models import Product, InventoryParty, InventoryBill, InventoryEntry
        from .views.helpers import _build_inventory_dashboard_metrics

        party = InventoryParty.objects.create(
            workspace=self.workspace,
            name='Test Supplier',
            party_type='supplier',
        )
        product = Product.objects.create(
            workspace=self.workspace,
            name='Test SSD',
            cost_price=Decimal('2000.00'),
            unit_price=Decimal('3500.00'),
            stock_quantity=50,
        )
        today = timezone.localdate()
        bill = InventoryBill.objects.create(
            workspace=self.workspace,
            bill_number='SB-METRIC-001',
            entry_type='sale',
            entry_date=today,
            party=party,
        )
        # Direct retail sale entry
        InventoryEntry.objects.create(
            workspace=self.workspace,
            bill=bill,
            entry_type='sale',
            entry_date=today,
            party=party,
            product=product,
            quantity=5,
            unit_price=Decimal('3500.00'),
            total_amount=Decimal('17500.00'),
        )

        metrics = _build_inventory_dashboard_metrics(workspace=self.workspace)
        self.assertEqual(metrics['total_in_stock_qty'], 50)
        self.assertEqual(metrics['monthly_sales_total'], Decimal('17500.00'))
        self.assertEqual(metrics['monthly_sales_cogs'], Decimal('10000.00'))  # 5 * 2000
        self.assertEqual(metrics['monthly_sales_profit'], Decimal('7500.00'))  # 17500 - 10000
        self.assertEqual(metrics['monthly_sales_margin_pct'], Decimal('42.9'))  # 7500 / 17500 * 100

    def test_job_linked_credit_bill_receives_payment_and_settles(self):
        from .models import InventoryParty, InventoryBill, InventoryCreditPayment
        from .views.helpers import (
            _build_inventory_credit_rows,
            _record_inventory_credit_payment,
        )

        party = InventoryParty.objects.create(
            workspace=self.workspace,
            name='Job Customer',
            party_type='customer',
        )
        job = JobTicket.objects.create(
            workspace=self.workspace,
            job_code='VAL-TASK-TEST-INV',
            customer_name='Job Customer',
            status='Closed',
            payment_status='unpaid',
            amount_paid=Decimal('0.00'),
        )
        ServiceLog.objects.create(
            job_ticket=job,
            description='Screen Repair',
            part_cost=Decimal('1500.00'),
            service_charge=Decimal('1000.00'),
        )
        bill = InventoryBill.objects.create(
            workspace=self.workspace,
            bill_number='SB-TEST-001',
            entry_type='sale',
            entry_date=timezone.localdate(),
            party=party,
            job_ticket=job,
        )

        # Before payment: should appear in receivables with balance 2500
        rows = _build_inventory_credit_rows('sale', workspace=self.workspace)
        matching = [r for r in rows if r.bill_id == bill.id]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0].balance_amount, Decimal('2500.00'))

        # Record payment via helper (simulating dashboard receive button)
        req = self.factory.post(
            '/staff/inventory/credit-payments/record/',
            {
                'bill_id': str(bill.id),
                'amount': '2500.00',
                'payment_method': 'cash',
                'payment_date': timezone.localdate().isoformat(),
            },
        )
        req.user = self.user
        req.current_workspace = self.workspace

        res = _record_inventory_credit_payment(req)
        self.assertIn('Receive Payment recorded for Job Customer', res['message'])

        # Verify job ticket was updated to paid
        job.refresh_from_db()
        self.assertEqual(job.payment_status, 'paid')
        self.assertEqual(job.amount_paid, Decimal('2500.00'))

        # Verify bill is no longer in open receivables
        rows_after = _build_inventory_credit_rows('sale', workspace=self.workspace)
        self.assertFalse(any(r.bill_id == bill.id for r in rows_after))


class TechnicianDashboardStockAndQualityTests(TestCase):
    def setUp(self):
        self.tech_user = User.objects.create_user(username='john_tech', password='password123')
        self.workspace = CompanyWorkspace.objects.create(name='Tech Workspace', owner=self.tech_user)
        tech_group, _ = Group.objects.get_or_create(name='Technicians')
        self.tech_user.groups.add(tech_group)
        self.technician = TechnicianProfile.objects.create(
            workspace=self.workspace,
            user=self.tech_user,
            unique_id='TECH-JOHN',
        )

        from .models import Product, InventoryParty, InventoryBill, InventoryEntry

        # Create a completed job with service charge, parts, and customer feedback
        self.job = JobTicket.objects.create(
            workspace=self.workspace,
            job_code='JOB-TECH-001',
            customer_name='Alice Customer',
            customer_phone='9876543210',
            device_type='Smartphone',
            device_brand='Apple',
            device_model='iPhone 13',
            status='Closed',
            assigned_to=self.technician,
            feedback_rating=9,
            feedback_comment='Amazing repair quality and very fast!',
            feedback_date=timezone.now(),
        )
        ServiceLog.objects.create(
            job_ticket=self.job,
            description='Display screen replacement',
            part_cost=Decimal('2000.00'),
            service_charge=Decimal('1500.00'),
        )

        # Create a product and direct over-the-counter stock sale by this technician
        self.product = Product.objects.create(
            workspace=self.workspace,
            name='USB-C Fast Charger 65W',
            sku='ACC-CHG-65W',
            unit_price=Decimal('1200.00'),
            cost_price=Decimal('600.00'),
        )
        self.customer_party = InventoryParty.objects.create(
            workspace=self.workspace,
            name='Walk-in Retail Buyer',
            party_type='customer',
        )
        self.bill = InventoryBill.objects.create(
            workspace=self.workspace,
            bill_number='SB-RETAIL-001',
            entry_type='sale',
            entry_date=timezone.localdate(),
            party=self.customer_party,
            created_by=self.tech_user,
        )
        self.stock_entry = InventoryEntry.objects.create(
            workspace=self.workspace,
            bill=self.bill,
            party=self.customer_party,
            product=self.product,
            entry_type='sale',
            entry_date=timezone.localdate(),
            quantity=2,
            unit_price=Decimal('1200.00'),
            total_amount=Decimal('2400.00'),
            created_by=self.tech_user,
        )

    def test_technician_dashboard_stock_sales_and_quality_feedback_render(self):
        self.client.login(username='john_tech', password='password123')
        response = self.client.get(reverse('technician_dashboard'))
        self.assertEqual(response.status_code, 200)

        content = response.content.decode('utf-8')

        # Stock Sales checks - included directly in table with Stock Sale column, no separate table
        self.assertNotIn('Direct Stock Sales (Retail / Inventory)', content)
        self.assertIn('Stock Sale', content)
        self.assertIn('USB-C Fast Charger 65W', content)
        self.assertIn('2400.00', content)
        self.assertIn('data-bs-toggle="tooltip"', content)
        self.assertIn('title="Direct over-the-counter retail inventory product sales', content)

        # Quality & Feedback pill on dashboard
        self.assertIn('/technician-feedback/', content)
        self.assertIn('9.0', content)
        self.assertIn('1 review', content)

        # Dedicated Technician Feedback page check
        fb_resp = self.client.get(reverse('technician_feedback'))
        self.assertEqual(fb_resp.status_code, 200)
        fb_content = fb_resp.content.decode('utf-8')
        self.assertIn('Quality & Customer Feedback', fb_content)
        self.assertIn('Amazing repair quality and very fast!', fb_content)
        self.assertIn('Alice Customer', fb_content)
        self.assertIn('9/10', fb_content)
        self.assertIn('Quality Index', fb_content)

        # Service terminology check
        self.assertIn('Service Charge', content)
        self.assertNotIn('Labor Charges', content)
        self.assertNotIn('Technician Labor', content)

    def test_technician_dashboard_ajax_filter_returns_stock_totals(self):
        self.client.login(username='john_tech', password='password123')
        response = self.client.get(
            reverse('technician_dashboard'),
            {'preset': 'this_month'},
            HTTP_X_REQUESTED_WITH='XMLHttpRequest',
        )
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn('html', data)
        self.assertIn('active_jobs_html', data)
        self.assertEqual(data.get('history_stock_total'), '2400.00')
        self.assertEqual(data.get('history_stock_count'), 1)
        self.assertEqual(data.get('history_service_total'), '1500.00')
        self.assertIn('USB-C Fast Charger 65W', data['html'])

    def test_reports_dashboard_todays_activity_includes_stock_sales(self):
        admin_user = User.objects.create_user(username='reports_admin', password='password123', is_staff=True)
        apply_staff_access(admin_user, {'reports_dashboard', 'reports_overview', 'reports_financial'})
        self.client.login(username='reports_admin', password='password123')

        response = self.client.get(reverse('reports_dashboard'))
        self.assertEqual(response.status_code, 200)

        content = response.content.decode('utf-8')
        self.assertIn("Today's activity", content)
        self.assertIn("Stock Sales", content)
        self.assertIn("Retail / OTC", content)
        self.assertIn("Direct over-the-counter retail inventory product sales made today", content)
        self.assertIn("2400.00", content)


