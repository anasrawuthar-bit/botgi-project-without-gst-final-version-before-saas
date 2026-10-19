from collections import defaultdict
from datetime import datetime, timedelta

from .helpers import *  # noqa: F401,F403
from .helpers import (
    _inventory_bill_total,
    _inventory_credit_payment_totals,
    _money_or_zero,
    _net_amount_after_discount,
    _staff_access_required,
    _sum_job_discounts,
)


def get_monthly_closed_and_ready_breakdown(workspace=None, technician=None):
    """Computes a historical month-by-month breakdown of:
    1. Closed jobs count & closed total value (realized revenue)
    2. Ready for pickup jobs count & ready total value (every job that ever transitioned to Ready for Pickup in that month)
    3. Linked credit bills total & outstanding balance for closed jobs
    4. Hides months where both values/counts are zero.
    Optionally scoped to a specific technician.
    """
    from collections import defaultdict
    from datetime import datetime

    qs = scope_to_workspace(JobTicket.objects, workspace)
    if technician is not None:
        qs = qs.filter(assigned_to=technician)

    scoped_jobs = list(with_report_dates(qs).prefetch_related('service_logs'))
    calculate_job_totals(scoped_jobs)
    job_map = {j.id: j for j in scoped_jobs}

    closed_jobs_map = {}
    closed_by_month = defaultdict(lambda: {
        'count': 0,
        'value': Decimal('0.00'),
        'part_cost': Decimal('0.00'),
        'service_charge': Decimal('0.00'),
    })
    for j in scoped_jobs:
        if j.status == 'Closed':
            dt = getattr(j, 'report_closed_at', None) or j.closed_at or j.updated_at
            if dt:
                loc_dt = timezone.localtime(dt) if timezone.is_aware(dt) else dt
                m_key = loc_dt.strftime('%Y-%m')
                closed_by_month[m_key]['count'] += 1
                closed_by_month[m_key]['value'] += j.grand_total
                closed_by_month[m_key]['part_cost'] += getattr(j, 'part_total', Decimal('0.00'))
                closed_by_month[m_key]['service_charge'] += getattr(j, 'service_total', Decimal('0.00'))
                closed_jobs_map[j.id] = m_key

    credit_by_month = defaultdict(lambda: {'bill_total': Decimal('0.00'), 'balance_total': Decimal('0.00'), 'paid_total': Decimal('0.00')})
    if closed_jobs_map:
        bills = list(
            InventoryBill.objects
            .filter(entry_type='sale', job_ticket_id__in=closed_jobs_map.keys())
            .annotate(bill_total=Coalesce(Sum('lines__total_amount', output_field=DecimalField()), Decimal('0.00')))
            .order_by('entry_date', 'id')
        )
        direction = InventoryCreditPayment.DIRECTION_RECEIVABLE
        payment_totals = _inventory_credit_payment_totals([bill.id for bill in bills])

        for bill in bills:
            m_key = closed_jobs_map.get(bill.job_ticket_id)
            if m_key:
                job = job_map.get(bill.job_ticket_id)
                total_amount = _money_or_zero(getattr(bill, 'bill_total', Decimal('0.00')))
                if total_amount <= Decimal('0.00') and job:
                    total_amount = _inventory_bill_total(bill)
                paid_amount = _money_or_zero(payment_totals.get((bill.id, direction), Decimal('0.00')))
                if job:
                    paid_amount = max(paid_amount, _money_or_zero(job.amount_paid))
                    if job.payment_status == 'paid' and (total_amount - paid_amount) > Decimal('0.00'):
                        paid_amount = total_amount
                balance_amount = max(Decimal('0.00'), total_amount - paid_amount)

                credit_by_month[m_key]['bill_total'] += total_amount
                credit_by_month[m_key]['paid_total'] += paid_amount
                credit_by_month[m_key]['balance_total'] += balance_amount

    ready_by_month = defaultdict(lambda: {
        'jobs': set(),
        'value': Decimal('0.00'),
        'part_cost': Decimal('0.00'),
        'service_charge': Decimal('0.00'),
    })
    for j in scoped_jobs:
        if j.status in ['Ready for Pickup', 'Completed']:
            dt = getattr(j, 'report_completed_at', None) or getattr(j, 'report_date', None) or j.updated_at
            if dt:
                loc_dt = timezone.localtime(dt) if timezone.is_aware(dt) else dt
                m_key = loc_dt.strftime('%Y-%m')
                if j.id not in ready_by_month[m_key]['jobs']:
                    ready_by_month[m_key]['jobs'].add(j.id)
                    ready_by_month[m_key]['value'] += j.grand_total
                    ready_by_month[m_key]['part_cost'] += getattr(j, 'part_total', Decimal('0.00'))
                    ready_by_month[m_key]['service_charge'] += getattr(j, 'service_total', Decimal('0.00'))

    stock_by_month = defaultdict(lambda: Decimal('0.00'))
    if technician is not None and getattr(technician, 'user_id', None):
        t_user_id = technician.user_id
        tech_stock_entries = scope_to_workspace(
            InventoryEntry.objects.filter(
                entry_type__in=['sale', 'sale_return'],
                job_ticket__isnull=True,
                bill__is_reversed=False,
            ).filter(
                Q(created_by_id=t_user_id) | Q(bill__created_by_id=t_user_id)
            ),
            workspace,
        ).values('entry_date', 'entry_type', 'total_amount')
        for se in tech_stock_entries:
            ed = se.get('entry_date')
            if ed:
                m_key = ed.strftime('%Y-%m')
                amt = se.get('total_amount') or Decimal('0.00')
                if se.get('entry_type') == 'sale':
                    stock_by_month[m_key] += amt
                elif se.get('entry_type') == 'sale_return':
                    stock_by_month[m_key] -= amt

    all_months = sorted(set(list(closed_by_month.keys()) + list(ready_by_month.keys()) + list(stock_by_month.keys())), reverse=True)
    monthly_breakdown = []
    for m in all_months:
        c_info = closed_by_month.get(m, {'count': 0, 'value': Decimal('0.00'), 'part_cost': Decimal('0.00'), 'service_charge': Decimal('0.00')})
        r_info = ready_by_month.get(m, {'jobs': set(), 'value': Decimal('0.00'), 'part_cost': Decimal('0.00'), 'service_charge': Decimal('0.00')})
        cr_info = credit_by_month.get(m, {'bill_total': Decimal('0.00'), 'balance_total': Decimal('0.00')})
        c_val = c_info['value']
        r_val = r_info['value']
        c_cnt = c_info['count']
        r_cnt = len(r_info['jobs'])
        cr_total = cr_info['bill_total']
        cr_bal = cr_info['balance_total']

        p_val = c_info['part_cost'] + r_info['part_cost']
        s_val = c_info['service_charge'] + r_info['service_charge']
        stock_val = stock_by_month.get(m, Decimal('0.00'))

        # Hide zero months
        if c_cnt == 0 and r_cnt == 0 and c_val == Decimal('0.00') and r_val == Decimal('0.00') and cr_total == Decimal('0.00') and cr_bal == Decimal('0.00') and p_val == Decimal('0.00') and s_val == Decimal('0.00') and stock_val == Decimal('0.00'):
            continue
        try:
            m_dt = datetime.strptime(m, '%Y-%m')
            month_label = m_dt.strftime('%B %Y')
            month_short = m_dt.strftime('%b %Y')
        except ValueError:
            month_label = m
            month_short = m

        monthly_breakdown.append({
            'month_key': m,
            'month_label': month_label,
            'month_short': month_short,
            'closed_count': c_cnt,
            'closed_value': c_val,
            'closed_part_cost': c_info['part_cost'],
            'closed_service_charge': c_info['service_charge'],
            'credit_bills': cr_total,
            'credit_bill_total': cr_total,
            'credit_balance': cr_bal,
            'outstanding_balance': cr_bal,
            'ready_count': r_cnt,
            'ready_value': r_val,
            'ready_part_cost': r_info['part_cost'],
            'ready_service_charge': r_info['service_charge'],
            'stock_sales': stock_val,
            'combined_value': c_val + r_val + stock_val,
            'part_cost': p_val,
            'service_charge': s_val,
            'parts_value': p_val,
            'service_value': s_val,
        })

    totals = {
        'closed_count': sum(r['closed_count'] for r in monthly_breakdown),
        'closed_value': sum(r['closed_value'] for r in monthly_breakdown),
        'credit_bills': sum(r['credit_bills'] for r in monthly_breakdown),
        'credit_bill_total': sum(r['credit_bill_total'] for r in monthly_breakdown),
        'credit_balance': sum(r['credit_balance'] for r in monthly_breakdown),
        'outstanding_balance': sum(r['outstanding_balance'] for r in monthly_breakdown),
        'ready_count': sum(r['ready_count'] for r in monthly_breakdown),
        'ready_value': sum(r['ready_value'] for r in monthly_breakdown),
        'stock_sales': sum(r.get('stock_sales', Decimal('0.00')) for r in monthly_breakdown),
        'combined_value': sum(r['combined_value'] for r in monthly_breakdown),
        'part_cost': sum(r['part_cost'] for r in monthly_breakdown),
        'service_charge': sum(r['service_charge'] for r in monthly_breakdown),
        'parts_value': sum(r['part_cost'] for r in monthly_breakdown),
        'service_value': sum(r['service_charge'] for r in monthly_breakdown),
    }

    return monthly_breakdown, totals


@login_required
@never_cache
def reports_dashboard(request):
    denied = _staff_access_required(request, "reports_dashboard")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    access = get_staff_access(request.user)
    period_tabs = [
        key for key in ['financial', 'daybook', 'technician', 'vendor']
        if (access.get('reports_financial') if key in ['financial', 'daybook'] else access.get('reports_' + key))
    ]
    allowed_tabs = ['overview'] + period_tabs if access.get('reports_overview') else period_tabs
    active_tab = request.GET.get('tab')
    if not active_tab or active_tab not in allowed_tabs:
        active_tab = 'financial' if 'financial' in period_tabs else (period_tabs[0] if period_tabs else 'overview')

    current_workspace = getattr(request, 'current_workspace', None)
    report_jobs = scope_to_workspace(JobTicket.objects, current_workspace)
    period = get_report_period(request)
    start_of_period = period['start']
    end_of_period = period['end']
    status_filter = request.GET.get('status_filter')

    # --- 1. ALL-TIME STATUS COUNTS (single aggregate query) ---
    status_counts = report_jobs.aggregate(
        all_jobs_count=Count('id'),
        pending_count=Count('id', filter=Q(status='Pending')),
        in_progress_count=Count('id', filter=Q(status__in=['Under Inspection', 'Repairing', 'Specialized Service'])),
        completed_count=Count('id', filter=Q(status='Completed')),
        ready_for_pickup_count=Count('id', filter=Q(status='Ready for Pickup')),
        returned_only_count=Count('id', filter=Q(status='Returned')),
        closed_count=Count('id', filter=Q(status='Closed')),
    )
    returned_to_closed_count = get_returned_to_closed_jobs(report_jobs).count()
    returned_count = status_counts['returned_only_count'] + returned_to_closed_count

    company_start_date = get_company_start_date()
    today = timezone.localdate()
    today_date_str = today.strftime('%Y-%m-%d')

    # Daybook Data (Live for Today and selected Daybook date)
    daybook_today = get_daily_daybook_context(today, workspace=current_workspace)
    daybook_date_str = (request.GET.get('daybook_date') or today_date_str).strip()
    daybook_data = get_daily_daybook_context(daybook_date_str, workspace=current_workspace) if active_tab == 'daybook' else daybook_today

    # Shared event selection keeps the cards and their detail pages aligned.
    todays_jobs_in = get_daily_report_jobs(today, 'in', current_workspace).count()
    todays_jobs_out_qs = get_daily_report_jobs(today, 'out', current_workspace)
    todays_jobs_out = todays_jobs_out_qs.count()
    todays_completed_jobs_qs = get_daily_report_jobs(today, 'completed', current_workspace)
    todays_jobs_completed = todays_completed_jobs_qs.count()

    def today_service_totals(jobs_queryset):
        rows = jobs_queryset.annotate(
            parts=Coalesce(Sum('service_logs__part_cost', output_field=DecimalField()), Decimal('0.00')),
            service=Coalesce(Sum('service_logs__service_charge', output_field=DecimalField()), Decimal('0.00')),
        ).values('parts', 'service', 'discount_amount')
        spare_total = service_total = net_total = Decimal('0.00')
        for row in rows:
            spare_total += row['parts']
            service_total += row['service']
            net_total += _net_amount_after_discount(row['parts'] + row['service'], row['discount_amount'])
        return spare_total, service_total, net_total

    todays_completed_spare, todays_completed_service, todays_completed_total = today_service_totals(todays_completed_jobs_qs)
    todays_closed_spare, todays_closed_service, todays_closed_total = today_service_totals(todays_jobs_out_qs)
    todays_total_spare = todays_completed_spare + todays_closed_spare
    todays_total_service = todays_completed_service + todays_closed_service

    # Today's Direct Stock Sales (Retail / Over-The-Counter)
    todays_stock_qs = scope_to_workspace(
        InventoryEntry.objects.filter(
            entry_type__in=['sale', 'sale_return'],
            entry_date=today,
            job_ticket__isnull=True,
            bill__is_reversed=False,
        ),
        current_workspace,
    ).select_related('bill', 'party', 'product')

    todays_stock_entries = list(todays_stock_qs)
    todays_stock_sales_count = len(todays_stock_entries)
    todays_stock_total = Decimal('0.00')
    todays_stock_units = 0
    todays_stock_cogs = Decimal('0.00')

    for entry in todays_stock_entries:
        amt = entry.total_amount or Decimal('0.00')
        qty = entry.quantity or 0
        cost_unit = entry.product.cost_price if (entry.product and entry.product.cost_price) else Decimal('0.00')
        line_cogs = cost_unit * Decimal(qty)
        if entry.entry_type == 'sale':
            todays_stock_total += amt
            todays_stock_units += qty
            todays_stock_cogs += line_cogs
        elif entry.entry_type == 'sale_return':
            todays_stock_total -= amt
            todays_stock_units -= qty
            todays_stock_cogs -= line_cogs

    todays_stock_profit = todays_stock_total - todays_stock_cogs

    # --- 3. PERIOD-BASED STATS (for tech/vendor performance tables) ---
    def parse_section_dates(start_str, end_str):
        if start_str and end_str:
            try:
                sd = datetime.strptime(start_str, '%Y-%m-%d').date()
                ed = datetime.strptime(end_str, '%Y-%m-%d').date()
                sd_aware, ed_aware = report_date_bounds(sd, ed)
                return sd_aware, ed_aware, min(sd, ed).isoformat(), max(sd, ed).isoformat()
            except ValueError:
                pass
        return start_of_period, end_of_period, period['start_date_str'], period['end_date_str']

    tech_start_str = request.GET.get('tech_start_date') or request.GET.get('perf_start_date')
    tech_end_str = request.GET.get('tech_end_date') or request.GET.get('perf_end_date')
    tech_start, tech_end, tech_start_date_str, tech_end_date_str = parse_section_dates(tech_start_str, tech_end_str)

    vendor_start_str = request.GET.get('vendor_start_date')
    vendor_end_str = request.GET.get('vendor_end_date')
    vendor_start, vendor_end, vendor_start_date_str, vendor_end_date_str = parse_section_dates(vendor_start_str, vendor_end_str)

    # Share financial totals with the printable and CSV summary.
    financial_summary = get_monthly_summary_context(
        start_of_period, end_of_period, period['start_date_str'], period['end_date_str'],
        workspace=current_workspace,
    ) if active_tab == 'financial' and access.get('reports_financial') else {}
    monthly_breakdown, monthly_breakdown_totals = ([], {})

    # Technician performance: count jobs completed in the period
    tech_finished_jobs = get_technician_jobs_for_period(
        tech_start,
        tech_end,
        workspace=current_workspace,
    )
    tech_finished_ids = list(tech_finished_jobs.values_list('id', flat=True))
    tech_log_agg = (
        ServiceLog.objects.filter(job_ticket__in=tech_finished_ids)
        .exclude(description__icontains='Specialized Service')
        .values('job_ticket__assigned_to')
        .annotate(
            parts=Coalesce(Sum('part_cost', output_field=DecimalField()), Decimal('0.00')),
            service=Coalesce(Sum('service_charge', output_field=DecimalField()), Decimal('0.00')),
        )
    )
    tech_log_map = {row['job_ticket__assigned_to']: row for row in tech_log_agg}
    tech_count_map = {
        row['assigned_to']: row['cnt']
        for row in (
            tech_finished_jobs.filter(assigned_to__isnull=False)
            .values('assigned_to')
            .annotate(cnt=Count('id'))
        )
    }
    tech_profiles = list(
        scope_to_workspace(TechnicianProfile.objects, current_workspace)
        .filter(user__groups__name='Technicians').select_related('user')
    )
    tech_user_ids = [tp.user_id for tp in tech_profiles if tp.user_id]
    direct_stock_qs = scope_to_workspace(
        InventoryEntry.objects.filter(
            entry_type__in=['sale', 'sale_return'],
            entry_date__gte=tech_start.date() if hasattr(tech_start, 'date') else tech_start,
            entry_date__lt=tech_end.date() if hasattr(tech_end, 'date') else tech_end,
            job_ticket__isnull=True,
            bill__is_reversed=False,
        ).filter(
            Q(created_by_id__in=tech_user_ids) | Q(bill__created_by_id__in=tech_user_ids)
        ),
        current_workspace,
    ).values('created_by_id', 'bill__created_by_id', 'entry_type', 'total_amount')

    tech_stock_map = defaultdict(lambda: Decimal('0.00'))
    for entry in direct_stock_qs:
        uid = entry['created_by_id'] or entry['bill__created_by_id']
        if not uid:
            continue
        amt = entry['total_amount'] or Decimal('0.00')
        if entry['entry_type'] == 'sale':
            tech_stock_map[uid] += amt
        elif entry['entry_type'] == 'sale_return':
            tech_stock_map[uid] -= amt

    for tp in tech_profiles:
        agg = tech_log_map.get(tp.id, {})
        tp.jobs_done = tech_count_map.get(tp.id, 0)
        tp.monthly_parts_sales = agg.get('parts', Decimal('0.00'))
        tp.monthly_stock_sales = tech_stock_map.get(tp.user_id, Decimal('0.00'))
        tp.monthly_service_sales = agg.get('service', Decimal('0.00'))
        tp.monthly_total_sales = tp.monthly_parts_sales + tp.monthly_stock_sales + tp.monthly_service_sales
    # Disabled technicians do not show up unless metrics are non-zero
    visible_tech_performance = [
        tp for tp in tech_profiles
        if (getattr(tp.user, 'is_active', True) or tp.jobs_done > 0 or tp.monthly_total_sales > Decimal('0.00'))
    ]
    monthly_tech_performance = sorted(visible_tech_performance, key=lambda x: x.jobs_done, reverse=True)
    tech_total_jobs = sum(tp.jobs_done for tp in monthly_tech_performance)
    tech_total_parts_sales = sum((tp.monthly_parts_sales for tp in monthly_tech_performance), Decimal('0.00'))
    tech_total_stock_sales = sum((tp.monthly_stock_sales for tp in monthly_tech_performance), Decimal('0.00'))
    tech_total_service_sales = sum((tp.monthly_service_sales for tp in monthly_tech_performance), Decimal('0.00'))
    tech_total_combined_sales = tech_total_parts_sales + tech_total_stock_sales + tech_total_service_sales

    # Vendor performance
    # Vendor detail reports count services returned in the selected period,
    # regardless of whether the customer has collected the device yet.
    vendor_finished_jobs = report_jobs.filter(
        specialized_service__returned_date__gte=vendor_start,
        specialized_service__returned_date__lt=vendor_end,
    )
    vendor_performance = scope_to_workspace(Vendor.objects, current_workspace).annotate(
        total_jobs_given=Count('services', filter=Q(services__job_ticket__in=vendor_finished_jobs)),
        total_vendor_cost=Coalesce(
            Sum(vendor_net_cost_expression('services__'),
                filter=Q(services__job_ticket__in=vendor_finished_jobs),
                output_field=DecimalField()),
            Decimal('0.00'),
        ),
        total_client_charge=Coalesce(
            Sum('services__client_charge',
                filter=Q(services__job_ticket__in=vendor_finished_jobs),
                output_field=DecimalField()),
            Decimal('0.00'),
        ),
    ).annotate(
        profit=F('total_client_charge') - F('total_vendor_cost')
    ).order_by('-total_jobs_given')
    vendor_total_jobs = sum(v.total_jobs_given for v in vendor_performance)
    vendor_total_cost = sum((v.total_vendor_cost for v in vendor_performance), Decimal('0.00'))
    vendor_total_client_charge = sum((v.total_client_charge for v in vendor_performance), Decimal('0.00'))
    vendor_total_profit = sum((v.profit for v in vendor_performance), Decimal('0.00'))

    context = {
        'active_tab': active_tab,
        # Today's Stats
        'todays_jobs_in': todays_jobs_in,
        'todays_jobs_out': todays_jobs_out,
        'todays_jobs_completed': todays_jobs_completed,
        'todays_total_spare': todays_total_spare,
        'todays_total_service': todays_total_service,
        'todays_completed_spare': todays_completed_spare,
        'todays_completed_service': todays_completed_service,
        'todays_completed_total': todays_completed_total,
        'todays_closed_spare': todays_closed_spare,
        'todays_closed_service': todays_closed_service,
        'todays_closed_total': todays_closed_total,
        'todays_stock_sales_count': todays_stock_sales_count,
        'todays_stock_total': todays_stock_total,
        'todays_stock_units': todays_stock_units,
        'todays_stock_cogs': todays_stock_cogs,
        'todays_stock_profit': todays_stock_profit,
        # Date/period metadata
        'preset': period.get('preset') or request.GET.get('preset', ''),
        'company_start_date': company_start_date.strftime('%Y-%m-%d'),
        'today_date_str': today_date_str,
        'current_report_start': period['start_date_str'],
        'current_report_end': period['end_date_str'],
        'tech_start_date': tech_start_date_str,
        'tech_end_date': tech_end_date_str,
        'vendor_start_date': vendor_start_date_str,
        'vendor_end_date': vendor_end_date_str,
        'status_filter': status_filter or 'ALL',
        'current_report_date': start_of_period,
        'financial_summary': financial_summary,
        'daybook_today': daybook_today,
        'daybook_data': daybook_data,
        'daybook_date_str': daybook_date_str,
        'monthly_breakdown': monthly_breakdown,
        'monthly_breakdown_totals': monthly_breakdown_totals,
        # All-Time Stats
        'all_jobs_count': status_counts['all_jobs_count'],
        'completed_count': status_counts['completed_count'],
        'completed_awaiting_billing_count': status_counts['completed_count'] + status_counts['ready_for_pickup_count'],
        'pending_count': status_counts['pending_count'],
        'in_progress_count': status_counts['in_progress_count'],
        'ready_for_pickup_count': status_counts['ready_for_pickup_count'],
        'returned_count': returned_count,
        'closed_count': status_counts['closed_count'],
        # The legacy archive markup is hidden; do not render every closed job (N+1 queries).
        'closed_jobs': (),
        # Performance
        'monthly_tech_performance': monthly_tech_performance,
        'tech_total_jobs': tech_total_jobs,
        'tech_total_parts_sales': tech_total_parts_sales,
        'tech_total_stock_sales': tech_total_stock_sales,
        'tech_total_service_sales': tech_total_service_sales,
        'tech_total_combined_sales': tech_total_combined_sales,
        'vendor_performance': vendor_performance,
        'vendor_total_jobs': vendor_total_jobs,
        'vendor_total_cost': vendor_total_cost,
        'vendor_total_client_charge': vendor_total_client_charge,
        'vendor_total_profit': vendor_total_profit,
    }
    return render(request, 'job_tickets/reports_dashboard.html', context)

@login_required
def reports_chart_data(request):
    """Return JSON aggregates (monthly + yearly) for the Reports Dashboard charts.

    Accepts the same query params as `reports_dashboard` (start_date, end_date, status_filter, preset).
    Uses `get_report_period()` so it shares the same defaults and timezone handling.
    """
    access = get_staff_access(request.user)
    if not request.user.is_staff or not access.get("reports_overview"):
        return JsonResponse({'error': 'Unauthorized'}, status=403)

    period = get_report_period(request)
    start_of_period = period['start']
    end_of_period = period['end']
    status_filter = request.GET.get('status_filter')

    finished_statuses = ['Completed', 'Closed']

    # Helper to apply status filter onto a base Q
    def apply_status_filter(q):
        if status_filter == 'ALL_FINISHED':
            q &= Q(status__in=finished_statuses)
        elif status_filter == 'ACTIVE_WORKLOAD':
            q &= Q(status__in=['Under Inspection', 'Repairing', 'Specialized Service'])
        elif status_filter and status_filter != 'ALL':
            q &= Q(status=status_filter)
        return q

    # Iterate month-by-month from start_of_period (inclusive) to end_of_period (exclusive)
    monthly = []
    current = start_of_period
    while current < end_of_period:
        # month start is current
        month_start = current
        # compute next month start
        if month_start.month == 12:
            next_month = month_start.replace(year=month_start.year + 1, month=1, day=1)
        else:
            next_month = month_start.replace(month=month_start.month + 1, day=1)

        # Get jobs for this month using vendor concept
        monthly_jobs_list = get_jobs_for_report_period(
            month_start,
            min(next_month, end_of_period),
            status_filter,
            workspace=getattr(request, 'current_workspace', None),
        )
        jobs_qs = scope_to_workspace(
            JobTicket.objects,
            getattr(request, 'current_workspace', None),
        ).filter(id__in=[job.id for job in monthly_jobs_list])
        jobs_count = len(monthly_jobs_list)

        logs_qs = ServiceLog.objects.filter(job_ticket__in=jobs_qs)
        parts_total = logs_qs.aggregate(total=Coalesce(Sum('part_cost', output_field=DecimalField()), Decimal('0.00')))['total']
        service_total = logs_qs.aggregate(total=Coalesce(Sum('service_charge', output_field=DecimalField()), Decimal('0.00')))['total']
        discount_total = _sum_job_discounts(jobs_qs)
        total_income = _net_amount_after_discount(parts_total + service_total, discount_total)

        vendor_qs = SpecializedService.objects.filter(job_ticket__in=jobs_qs)
        vendor_expense = sum_vendor_net_cost(vendor_qs)

        monthly.append({
            'label': month_start.strftime('%Y-%m'),
            'jobs_finished': int(jobs_count),
            'parts_income': float(parts_total),
            'service_income': float(service_total),
            'discount_total': float(discount_total),
            'total_income': float(total_income),
            'vendor_expense': float(vendor_expense),
            'net_profit': float(total_income - vendor_expense),
        })

        current = next_month

    # Yearly aggregates: compute year by year in the same range
    yearly = []
    start_year = start_of_period.year
    end_year = (end_of_period - timedelta(seconds=1)).year
    for yr in range(start_year, end_year + 1):
        y_start = timezone.make_aware(datetime(yr, 1, 1))
        y_end = timezone.make_aware(datetime(yr + 1, 1, 1))
        
        # Get jobs for this year using vendor concept
        yearly_jobs_list = get_jobs_for_report_period(
            max(y_start, start_of_period),
            min(y_end, end_of_period),
            status_filter,
            workspace=getattr(request, 'current_workspace', None),
        )
        jobs_qs = scope_to_workspace(
            JobTicket.objects,
            getattr(request, 'current_workspace', None),
        ).filter(id__in=[job.id for job in yearly_jobs_list])
        jobs_count = len(yearly_jobs_list)

        logs_qs = ServiceLog.objects.filter(job_ticket__in=jobs_qs)
        parts_total = logs_qs.aggregate(total=Coalesce(Sum('part_cost', output_field=DecimalField()), Decimal('0.00')))['total']
        service_total = logs_qs.aggregate(total=Coalesce(Sum('service_charge', output_field=DecimalField()), Decimal('0.00')))['total']
        discount_total = _sum_job_discounts(jobs_qs)
        total_income = _net_amount_after_discount(parts_total + service_total, discount_total)

        vendor_qs = SpecializedService.objects.filter(job_ticket__in=jobs_qs)
        vendor_expense = sum_vendor_net_cost(vendor_qs)

        yearly.append({
            'year': yr,
            'jobs_finished': int(jobs_count),
            'discount_total': float(discount_total),
            'total_income': float(total_income),
            'vendor_expense': float(vendor_expense),
            'net_profit': float(total_income - vendor_expense),
        })

    return JsonResponse({'monthly': monthly, 'yearly': yearly})

# job_tickets/views.py

# job_tickets/views.py

def _build_technician_report_context(request, tech_id):
    finished_statuses = ['Completed', 'Ready for Pickup', 'Closed']
    technician = get_object_or_404(
        scope_to_workspace(TechnicianProfile.objects, getattr(request, 'current_workspace', None)),
        id=tech_id,
    )

    # 1. GET DATE & STATUS FILTERS from URL (These are passed from the Reports Dashboard or filter bar)
    start_date_str = request.GET.get('start_date')
    end_date_str = request.GET.get('end_date')
    status_filter = (request.GET.get('status') or '').strip()

    if status_filter in ['Ready for Pickup', 'Closed', 'Completed']:
        selected_statuses = [status_filter]
    elif status_filter in ['ready_and_closed', 'ready_closed']:
        selected_statuses = ['Ready for Pickup', 'Closed']
    else:
        status_filter = 'all'
        selected_statuses = finished_statuses

    # Start with base filters: assigned technician and selected statuses
    jobs_filter = Q(assigned_to=technician, status__in=selected_statuses)

    # 2. APPLY DATE FILTERING
    if start_date_str and end_date_str:
        try:
            start_date = datetime.strptime(start_date_str, '%Y-%m-%d').date()
            end_date = datetime.strptime(end_date_str, '%Y-%m-%d').date()
            if end_date < start_date:
                start_date, end_date = end_date, start_date
                start_date_str = start_date.isoformat()
                end_date_str = end_date.isoformat()

            start_of_period, end_of_period = report_date_bounds(start_date, end_date)
            period_jobs = get_technician_jobs_for_period(
                start_of_period, end_of_period,
                workspace=getattr(request, 'current_workspace', None),
            )
            jobs_filter &= Q(pk__in=[job.pk for job in period_jobs])

        except ValueError:
            messages.error(request, "Invalid date format provided for report filtering.")
            # If dates are bad, the report defaults to All Time (jobs_filter remains simple)
            start_date_str = None
            end_date_str = None
    else:
        # If no dates provided, ensure variables are None to display 'All Time' header
        start_date_str = None
        end_date_str = None

    # 3. Fetch Jobs
    jobs = list(
        with_report_dates(scope_to_workspace(
            JobTicket.objects,
            getattr(request, 'current_workspace', None),
        )).filter(jobs_filter)
        .prefetch_related('service_logs')
        .order_by('-report_date', '-id')
    )

    # 4. Calculate Totals excluding vendor service charges
    calculate_job_totals(jobs, exclude_vendor_charges=True)

    total_parts_all = sum(job.part_total for job in jobs)
    total_services_all = sum(job.service_total for job in jobs)
    total_discounts_all = Decimal('0.00')
    total_income = Decimal('0.00')
    for job in jobs:
        job.discount_total = _money_or_zero(job.discount_amount)
        job.net_total = _net_amount_after_discount(job.total, job.discount_total)
        job.device_label = ' '.join(
            part for part in [job.device_type, job.device_brand, job.device_model]
            if part
        )
        total_discounts_all += job.discount_total
        total_income += job.net_total

    jobs_count = len(jobs)
    completed_count = sum(1 for job in jobs if job.status == 'Completed')
    ready_count = sum(1 for job in jobs if job.status == 'Ready for Pickup')
    closed_count = sum(1 for job in jobs if job.status == 'Closed')
    average_income = total_income / jobs_count if jobs_count else Decimal('0.00')
    technician_name = technician.user.get_full_name() or technician.user.username
    query_params = {}
    if start_date_str and end_date_str:
        query_params['start_date'] = start_date_str
        query_params['end_date'] = end_date_str
    if status_filter and status_filter != 'all':
        query_params['status'] = status_filter
    period_query = urlencode(query_params)

    def _format_tat_duration(seconds):
        if seconds is None:
            return "-"
        if seconds <= 0:
            return "< 1m"
        seconds = int(seconds)
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        minutes = (seconds % 3600) // 60
        if days > 0:
            if hours > 0:
                return f"{days}d {hours}h"
            return f"{days}d"
        if hours > 0:
            if minutes > 0:
                return f"{hours}h {minutes}m"
            return f"{hours}h"
        return f"{max(1, minutes)}m"

    # 5. Turnaround Time (TAT), Delivery SLA & Profit Calculations per Job
    job_ids = [job.id for job in jobs]
    expense_agg = {
        row['job_ticket']: row['total']
        for row in Expense.objects.filter(job_ticket__in=job_ids).values('job_ticket').annotate(total=Sum('amount'))
    }
    inventory_agg = {
        row['job_ticket']: row['total']
        for row in ProductSale.objects.filter(job_ticket__in=job_ids).values('job_ticket').annotate(total=Sum('line_cost'))
    }

    total_profit_all = Decimal('0.00')
    total_expenses_all = Decimal('0.00')
    total_tat_seconds = 0
    fast_track_count = 0
    sla_tracked_count = 0
    sla_on_time_count = 0

    for job in jobs:
        # Turnaround Time
        completed_time = getattr(job, 'report_completed_at', None) or getattr(job, 'report_date', None) or job.updated_at
        created_time = job.created_at
        if completed_time and created_time:
            tat_sec = max(0, int((completed_time - created_time).total_seconds()))
        else:
            tat_sec = 0
        job.tat_seconds = tat_sec
        job.tat_display = _format_tat_duration(tat_sec)
        job.is_fast_track = (tat_sec <= 86400)
        if job.is_fast_track:
            fast_track_count += 1
        total_tat_seconds += tat_sec

        # On-Time Delivery Tracking
        if job.estimated_delivery and completed_time:
            sla_tracked_count += 1
            completed_date = timezone.localtime(completed_time).date()
            job.is_on_time = (completed_date <= job.estimated_delivery)
            if job.is_on_time:
                sla_on_time_count += 1
            job.delivery_status = 'On Time' if job.is_on_time else 'Overdue'
        else:
            job.is_on_time = None
            job.delivery_status = None

        # Profit & Margin
        job.expenses_total = expense_agg.get(job.id, Decimal('0.00'))
        job.inventory_cost = inventory_agg.get(job.id, Decimal('0.00'))
        job.direct_cost = job.expenses_total + job.inventory_cost
        job.profit = job.net_total - job.direct_cost
        job.profit_margin_pct = (job.profit / job.net_total * 100) if job.net_total > Decimal('0.00') else Decimal('0.00')

        total_expenses_all += job.direct_cost
        total_profit_all += job.profit

    avg_tat_seconds = (total_tat_seconds / jobs_count) if jobs_count else 0
    avg_tat_display = _format_tat_duration(avg_tat_seconds)
    fast_track_pct = int(round(fast_track_count / jobs_count * 100)) if jobs_count else 0
    on_time_rate = int(round(sla_on_time_count / sla_tracked_count * 100)) if sla_tracked_count else None
    average_profit = (total_profit_all / jobs_count) if jobs_count else Decimal('0.00')
    overall_margin_pct = (total_profit_all / total_income * 100) if total_income > Decimal('0.00') else Decimal('0.00')
    labor_pct = int(round(total_services_all / total_income * 100)) if total_income > Decimal('0.00') else 0

    # 6. Peer Benchmark & Shop Comparison ("Any Better Than Me")
    workspace = getattr(request, 'current_workspace', None)
    shop_filter = Q(status__in=finished_statuses)
    if start_date_str and end_date_str:
        try:
            shop_filter &= Q(pk__in=[j.pk for j in period_jobs])
        except (NameError, UnboundLocalError):
            pass
    shop_jobs = list(
        with_report_dates(scope_to_workspace(JobTicket.objects, workspace))
        .filter(shop_filter)
        .prefetch_related('service_logs')
    )
    calculate_job_totals(shop_jobs, exclude_vendor_charges=True)

    shop_total_jobs = len(shop_jobs)
    workload_share_pct = int(round(jobs_count / shop_total_jobs * 100)) if shop_total_jobs else 100

    tech_vol_map = {}
    tech_rev_map = {}
    shop_tat_list = []
    shop_income_total = Decimal('0.00')

    for sj in shop_jobs:
        tid = sj.assigned_to_id
        tech_vol_map[tid] = tech_vol_map.get(tid, 0) + 1
        sj_net = _net_amount_after_discount(sj.total, _money_or_zero(sj.discount_amount))
        tech_rev_map[tid] = tech_rev_map.get(tid, Decimal('0.00')) + sj_net
        shop_income_total += sj_net
        s_done = getattr(sj, 'report_completed_at', None) or getattr(sj, 'report_date', None) or sj.updated_at
        start_time = sj.created_at
        if getattr(sj, 'intake_date', None) and sj.created_at:
            intake_dt = timezone.make_aware(datetime.combine(sj.intake_date, datetime.min.time()))
            if intake_dt < sj.created_at:
                start_time = intake_dt
        if s_done and start_time:
            shop_tat_list.append(max(0, int((s_done - start_time).total_seconds())))

    sorted_vol = sorted(tech_vol_map.keys(), key=lambda t: tech_vol_map[t], reverse=True)
    sorted_rev = sorted(tech_rev_map.keys(), key=lambda t: tech_rev_map[t], reverse=True)
    rank_vol = (sorted_vol.index(technician.id) + 1) if technician.id in sorted_vol else 1
    rank_rev = (sorted_rev.index(technician.id) + 1) if technician.id in sorted_rev else 1
    total_active_techs = max(len(sorted_vol), 1)

    shop_avg_tat_sec = (sum(shop_tat_list) / len(shop_tat_list)) if shop_tat_list else avg_tat_seconds
    shop_avg_tat_display = _format_tat_duration(shop_avg_tat_sec)
    shop_avg_income = (shop_income_total / shop_total_jobs) if shop_total_jobs else average_income

    if total_active_techs == 1 or shop_total_jobs <= jobs_count:
        tat_benchmark_text = "Leading shop pace"
        ticket_benchmark_text = "Shop standard"
        benchmark_headline = f"Primary Technician • Handled {workload_share_pct}% of total shop volume"
    else:
        if avg_tat_seconds < shop_avg_tat_sec and shop_avg_tat_sec > 0:
            diff = int(round((shop_avg_tat_sec - avg_tat_seconds) / shop_avg_tat_sec * 100))
            tat_benchmark_text = f"{diff}% faster than shop avg ⚡"
        elif avg_tat_seconds > shop_avg_tat_sec and shop_avg_tat_sec > 0:
            diff = int(round((avg_tat_seconds - shop_avg_tat_sec) / shop_avg_tat_sec * 100))
            tat_benchmark_text = f"{diff}% slower than shop avg"
        else:
            tat_benchmark_text = "On par with shop avg"

        if average_income > shop_avg_income and shop_avg_income > 0:
            rev_diff = int(round((average_income - shop_avg_income) / shop_avg_income * 100))
            ticket_benchmark_text = f"+{rev_diff}% above shop avg"
        elif average_income < shop_avg_income and shop_avg_income > 0:
            rev_diff = int(round((shop_avg_income - average_income) / shop_avg_income * 100))
            ticket_benchmark_text = f"-{rev_diff}% below shop avg"
        else:
            ticket_benchmark_text = "Equal to shop avg"

        if rank_vol == 1:
            benchmark_headline = f"#1 Top Performer in Volume ({workload_share_pct}% of shop output)"
        else:
            benchmark_headline = f"Rank #{rank_vol} of {total_active_techs} Active Technicians ({workload_share_pct}% of shop output)"

    # Direct Stock Sales (Over-The-Counter Retail) attributed to this technician
    stock_qs = scope_to_workspace(
        InventoryEntry.objects.filter(
            entry_type__in=['sale', 'sale_return'],
            job_ticket__isnull=True,
            bill__is_reversed=False,
        ).filter(
            Q(created_by_id=technician.user_id) | Q(bill__created_by_id=technician.user_id)
        ),
        workspace,
    ).select_related('bill', 'party', 'product').order_by('-entry_date', '-id')

    if start_date_str and end_date_str:
        try:
            sd = datetime.strptime(start_date_str, '%Y-%m-%d').date()
            ed = datetime.strptime(end_date_str, '%Y-%m-%d').date()
            if ed < sd:
                sd, ed = ed, sd
            stock_qs = stock_qs.filter(entry_date__gte=sd, entry_date__lte=ed)
        except ValueError:
            pass

    stock_sales = list(stock_qs)
    stock_sales_count = len(stock_sales)
    total_stock_sales_amount = Decimal('0.00')
    total_stock_units = 0
    total_stock_cogs = Decimal('0.00')

    for entry in stock_sales:
        qty = entry.quantity or 0
        amt = entry.total_amount or Decimal('0.00')
        cost_unit = entry.product.cost_price if (entry.product and entry.product.cost_price) else Decimal('0.00')
        line_cogs = cost_unit * Decimal(qty)
        line_profit = amt - line_cogs
        entry.line_cogs = line_cogs
        entry.line_profit = line_profit

        if entry.entry_type == 'sale':
            total_stock_sales_amount += amt
            total_stock_units += qty
            total_stock_cogs += line_cogs
        elif entry.entry_type == 'sale_return':
            total_stock_sales_amount -= amt
            total_stock_units -= qty
            total_stock_cogs -= line_cogs

    total_stock_profit = total_stock_sales_amount - total_stock_cogs
    total_combined_revenue = total_income + total_stock_sales_amount
    total_combined_profit = total_profit_all + total_stock_profit

    monthly_breakdown, monthly_breakdown_totals = get_monthly_closed_and_ready_breakdown(
        workspace=workspace,
        technician=technician,
    )

    import json
    chart_rows = list(reversed(monthly_breakdown))
    monthly_chart_data = {
        'labels': [r.get('month_short', r.get('month_label', '')) for r in chart_rows],
        'closed_value': [float(r['closed_value']) for r in chart_rows],
        'ready_value': [float(r['ready_value']) for r in chart_rows],
        'stock_sales': [float(r.get('stock_sales', 0)) for r in chart_rows],
        'combined_value': [float(r['combined_value']) for r in chart_rows],
        'part_cost': [float(r['part_cost']) for r in chart_rows],
        'service_charge': [float(r['service_charge']) for r in chart_rows],
        'closed_count': [r['closed_count'] for r in chart_rows],
        'ready_count': [r['ready_count'] for r in chart_rows],
        'total_count': [r['closed_count'] + r['ready_count'] for r in chart_rows],
    }
    monthly_chart_json = json.dumps(monthly_chart_data)

    return {
        'company': CompanyProfile.get_profile(getattr(request, 'current_workspace', None)),
        'technician': technician,
        'technician_name': technician_name,
        'jobs': jobs,
        'jobs_count': jobs_count,
        'ready_count': ready_count,
        'completed_count': completed_count,
        'closed_count': closed_count,
        'selected_status': status_filter,
        'total_parts': total_parts_all,
        'total_services': total_services_all,
        'total_discounts': total_discounts_all,
        'total_income': total_income,
        'average_income': average_income,
        # Performance Analytics & Profit
        'total_profit': total_profit_all,
        'average_profit': average_profit,
        'profit_margin_pct': overall_margin_pct,
        'total_expenses': total_expenses_all,
        'labor_pct': labor_pct,
        'avg_tat_display': avg_tat_display,
        'fast_track_count': fast_track_count,
        'fast_track_pct': fast_track_pct,
        'sla_tracked_count': sla_tracked_count,
        'sla_on_time_count': sla_on_time_count,
        'on_time_rate': on_time_rate,
        # Benchmarking
        'workload_share_pct': workload_share_pct,
        'rank_vol': rank_vol,
        'rank_rev': rank_rev,
        'total_active_techs': total_active_techs,
        'shop_avg_tat_display': shop_avg_tat_display,
        'shop_avg_income': shop_avg_income,
        'benchmark_headline': benchmark_headline,
        'tat_benchmark_text': tat_benchmark_text,
        'ticket_benchmark_text': ticket_benchmark_text,
        # Direct Stock Sales
        'stock_sales': stock_sales,
        'stock_sales_count': stock_sales_count,
        'total_stock_sales_amount': total_stock_sales_amount,
        'total_stock_units': total_stock_units,
        'total_stock_cogs': total_stock_cogs,
        'total_stock_profit': total_stock_profit,
        'total_combined_revenue': total_combined_revenue,
        'total_combined_profit': total_combined_profit,
        # Monthly Closed & Ready for Pickup Breakdown
        'monthly_breakdown': monthly_breakdown,
        'monthly_breakdown_totals': monthly_breakdown_totals,
        'monthly_chart_json': monthly_chart_json,
        # Pass dates for display in the report header
        'report_start_date': start_date_str,
        'report_end_date': end_date_str,
        'period_query': period_query,
        'generated_at': timezone.now(),
    }


@login_required
def technician_report_print(request, tech_id):
    denied = _staff_access_required(request, "reports_technician")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    context = _build_technician_report_context(request, tech_id)
    return render(request, 'job_tickets/technician_report_print.html', context)


@login_required
def technician_report_export_csv(request, tech_id):
    denied = _staff_access_required(request, "reports_technician")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    context = _build_technician_report_context(request, tech_id)
    safe_name = re.sub(r'[^A-Za-z0-9_-]+', '-', context['technician_name']).strip('-') or 'technician'
    status_suffix = f"_{context['selected_status'].lower().replace(' ', '_')}" if context.get('selected_status') and context['selected_status'] != 'all' else ''
    if context['report_start_date'] and context['report_end_date']:
        period_text = f"{context['report_start_date']}_to_{context['report_end_date']}"
    else:
        period_text = 'all_time'
    filename = f"technician_report_{safe_name}_{period_text}{status_suffix}.csv"

    response = HttpResponse(content_type='text/csv')
    response['Content-Disposition'] = f'attachment; filename="{filename}"'

    def money(value):
        return f"{(_money_or_zero(value)):.2f}"

    writer = csv.writer(response)
    writer.writerow(['Technician Report'])
    writer.writerow(['Technician', context['technician_name']])
    writer.writerow([
        'Period',
        f"{context['report_start_date']} to {context['report_end_date']}"
        if context['report_start_date'] and context['report_end_date']
        else 'All Time Completed/Closed Jobs',
    ])
    if context.get('selected_status') and context['selected_status'] != 'all':
        writer.writerow(['Status Filter', context['selected_status']])
    writer.writerow(['Generated At', timezone.localtime(context['generated_at']).strftime('%Y-%m-%d %H:%M')])
    writer.writerow([])
    writer.writerow(['Summary & Performance KPIs'])
    writer.writerow(['Jobs Counted', context['jobs_count']])
    writer.writerow(['Ready for Pickup Jobs', context['ready_count']])
    writer.writerow(['Completed Jobs', context['completed_count']])
    writer.writerow(['Closed Jobs', context['closed_count']])
    writer.writerow(['Shop Workload Share', f"{context['workload_share_pct']}%"])
    writer.writerow(['Shop Rank (Volume)', f"#{context['rank_vol']} of {context['total_active_techs']}"])
    writer.writerow(['Avg Turnaround Time (TAT)', context['avg_tat_display']])
    writer.writerow(['Fast-Track Rate (<= 24h)', f"{context['fast_track_pct']}%"])
    writer.writerow(['On-Time Delivery Rate', f"{context['on_time_rate']}%" if context['on_time_rate'] is not None else 'N/A'])
    writer.writerow(['Total Parts Sales', money(context['total_parts'])])
    writer.writerow(['Total Service Charges', money(context['total_services'])])
    writer.writerow(['Total Discounts', money(context['total_discounts'])])
    writer.writerow(['Jobs Net Revenue', money(context['total_income'])])
    writer.writerow(['Direct Stock Sales (Retail)', money(context['total_stock_sales_amount'])])
    writer.writerow(['Total Combined Revenue (Jobs + Stock)', money(context['total_combined_revenue'])])
    writer.writerow(['Average Net Per Job', money(context['average_income'])])
    writer.writerow(['Direct Costs / Expenses', money(context['total_expenses'])])
    writer.writerow(['Estimated Net Profit', money(context['total_profit'])])
    writer.writerow(['Total Combined Profit (Jobs + Stock)', money(context['total_combined_profit'])])
    writer.writerow(['Profit Margin', f"{context['profit_margin_pct']:.1f}%"])
    writer.writerow([])
    writer.writerow([
        'Job Code',
        'Customer',
        'Phone',
        'Device',
        'Status',
        'Report Date',
        'Turnaround (TAT)',
        'Delivery SLA',
        'Part Cost',
        'Service Charge',
        'Discount',
        'Net Total',
        'Direct Cost',
        'Est Profit',
        'Job URL',
    ])
    for job in context['jobs']:
        writer.writerow([
            job.job_code,
            job.customer_name,
            job.customer_phone,
            job.device_label,
            job.status,
            timezone.localtime(job.report_date).strftime('%Y-%m-%d %H:%M') if job.report_date else '',
            job.tat_display,
            job.delivery_status or 'N/A',
            money(job.part_total),
            money(job.service_total),
            money(job.discount_total),
            money(job.net_total),
            money(job.direct_cost),
            money(job.profit),
            request.build_absolute_uri(reverse('staff_job_detail', args=[job.job_code])),
        ])

    if context.get('stock_sales'):
        writer.writerow([])
        writer.writerow(['Direct Stock Sales (Retail / Over-The-Counter)'])
        writer.writerow([
            'Bill Number',
            'Invoice',
            'Date',
            'Customer / Party',
            'Product',
            'SKU',
            'Quantity',
            'Unit Price',
            'Total Amount',
            'COGS',
            'Est Profit',
        ])
        for entry in context['stock_sales']:
            writer.writerow([
                entry.bill.bill_number if entry.bill else entry.entry_number,
                entry.invoice_number or '',
                entry.entry_date.strftime('%Y-%m-%d') if entry.entry_date else '',
                entry.party.name if entry.party else 'Walk-in Customer',
                entry.product.name if entry.product else '',
                entry.product.sku if (entry.product and entry.product.sku) else '',
                entry.quantity,
                money(entry.unit_price),
                money(entry.total_amount if entry.entry_type == 'sale' else -entry.total_amount),
                money(entry.line_cogs),
                money(entry.line_profit),
            ])

    return response

@login_required
def print_pending_jobs_report(request):
    access = get_staff_access(request.user)
    if not request.user.is_staff or not access.get("reports_overview"):
        return redirect('unauthorized')
    
    current_workspace = getattr(request, 'current_workspace', None)
    pending_jobs = list(
        scope_to_workspace(JobTicket.objects, current_workspace)
        .filter(status='Pending')
        .prefetch_related('service_logs')
        .order_by('created_at')
    )
    calculate_job_totals(pending_jobs)
    for job in pending_jobs:
        job.discount_total = _money_or_zero(job.discount_amount)
        job.net_total = _net_amount_after_discount(job.total, job.discount_total)
    company = CompanyProfile.get_profile()
    
    context = {
        'pending_jobs': pending_jobs,
        'report_date': datetime.now(),
        'company': company,
    }
    return render(request, 'job_tickets/print_pending_jobs_report.html', context)

@login_required
def print_monthly_summary_report(request):
    denied = _staff_access_required(request, "reports_financial")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    period = resolve_monthly_summary_period(request)
    current_workspace = getattr(request, 'current_workspace', None)
    context = get_monthly_summary_context(
        period['start_of_period'],
        period['end_of_period'],
        period['start_date_str'],
        period['end_date_str'],
        preset=period['preset'],
        show_jobs=period['show_jobs'],
        workspace=current_workspace,
    )
    monthly_breakdown, monthly_breakdown_totals = get_monthly_closed_and_ready_breakdown(
        workspace=current_workspace,
    )
    # Extract only working years with actual activity (months with zero values are already filtered)
    working_years = sorted(list({r['month_key'][:4] for r in monthly_breakdown if r.get('month_key')}), reverse=True)
    selected_breakdown_year = request.GET.get('breakdown_year', 'all').strip()
    if selected_breakdown_year not in working_years and selected_breakdown_year != 'all':
        selected_breakdown_year = 'all'

    context['monthly_breakdown'] = monthly_breakdown
    context['monthly_breakdown_totals'] = monthly_breakdown_totals
    context['working_years'] = working_years
    context['selected_breakdown_year'] = selected_breakdown_year

    # Provide monthly trend chart data for animated graphs
    rev_breakdown = list(reversed(monthly_breakdown))
    context['monthly_chart_json'] = json.dumps({
        'labels': [r['month_short'] for r in rev_breakdown],
        'years': [r['month_key'][:4] for r in rev_breakdown],
        'month_keys': [r['month_key'] for r in rev_breakdown],
        'closed_count': [r['closed_count'] for r in rev_breakdown],
        'closed_value': [float(r['closed_value']) for r in rev_breakdown],
        'ready_count': [r['ready_count'] for r in rev_breakdown],
        'ready_value': [float(r['ready_value']) for r in rev_breakdown],
        'parts_value': [float(r.get('part_cost', 0)) for r in rev_breakdown],
        'service_value': [float(r.get('service_charge', 0)) for r in rev_breakdown],
        'credit_bills': [float(r.get('credit_bills', 0)) for r in rev_breakdown],
        'outstanding_balance': [float(r.get('outstanding_balance', 0)) for r in rev_breakdown],
    })
    return render(request, 'job_tickets/print_monthly_summary_report.html', context)

@login_required
def print_daily_daybook_report(request):
    denied = _staff_access_required(request, "reports_financial")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    current_workspace = getattr(request, 'current_workspace', None)
    target_date_str = request.GET.get('date') or timezone.localdate().strftime('%Y-%m-%d')
    daybook = get_daily_daybook_context(target_date_str, workspace=current_workspace)
    profile = CompanyProfile.objects.filter(workspace=current_workspace).first() if current_workspace else CompanyProfile.objects.first()

    context = {
        'daybook': daybook,
        'profile': profile,
        'target_date_str': target_date_str,
        'printed_at': timezone.now(),
        'printed_by': request.user,
    }
    return render(request, 'job_tickets/print_daily_daybook_report.html', context)

@login_required
def export_daily_daybook_csv(request):
    denied = _staff_access_required(request, "reports_financial")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    current_workspace = getattr(request, 'current_workspace', None)
    target_date_str = request.GET.get('date') or timezone.localdate().strftime('%Y-%m-%d')
    daybook = get_daily_daybook_context(target_date_str, workspace=current_workspace)

    response = HttpResponse(content_type='text/csv')
    response['Content-Disposition'] = f'attachment; filename="daybook_{target_date_str}.csv"'

    writer = csv.writer(response)
    writer.writerow([f"Daily Daybook & Cash Reconciliation - {target_date_str}"])
    writer.writerow([])
    writer.writerow(["CASH DRAWER RECONCILIATION"])
    writer.writerow(["Opening Cash in Drawer", f"{daybook['opening_cash']:.2f}"])
    writer.writerow(["(+) Cash Receipts (Jobs & Sales)", f"{daybook['cash_inflows']:.2f}"])
    writer.writerow(["(-) Cash Outflows (Expenses)", f"{daybook['cash_outflows']:.2f}"])
    writer.writerow(["(-) Cash Deposited to Bank (Contra)", f"{daybook['cash_to_bank']:.2f}"])
    writer.writerow(["(+) Cash Withdrawn from Bank (Contra)", f"{daybook['bank_to_cash']:.2f}"])
    writer.writerow(["(=) Physical Expected Cash in Drawer", f"{daybook['closing_cash']:.2f}"])
    writer.writerow([])
    writer.writerow(["BANK & DIGITAL RECONCILIATION"])
    writer.writerow(["(+) Bank & UPI Receipts", f"{daybook['bank_inflows']:.2f}"])
    writer.writerow(["(-) Bank Expenses & Outflows", f"{daybook['bank_outflows']:.2f}"])
    writer.writerow(["Net Bank Flow", f"{daybook['net_bank_flow']:.2f}"])
    writer.writerow([])
    writer.writerow(["ACCOUNT BALANCES"])
    writer.writerow(["Account Name", "Type", "Receipts Today", "Payments Today", "Transfers In", "Transfers Out", "Current Balance"])
    for row in daybook['account_rows']:
        writer.writerow([
            row['name'],
            row['type_display'],
            f"{row['inflows']:.2f}",
            f"{row['outflows']:.2f}",
            f"{row['transfers_in']:.2f}",
            f"{row['transfers_out']:.2f}",
            f"{row['current_balance']:.2f}",
        ])
    writer.writerow([])
    writer.writerow(["ITEMIZED AUDIT TRANSACTIONS"])
    writer.writerow(["Time", "Account", "Type", "Amount", "Balance After", "Description", "Ref No", "Source Link", "Staff"])
    for txn in daybook['transactions']:
        job_code = txn.job_ticket.job_code if txn.job_ticket else ""
        exp_desc = f"Exp #{txn.expense_id}" if txn.expense else ""
        link_str = job_code or exp_desc or (f"Transfer to/from {txn.transfer_counterpart.account.name}" if txn.transfer_counterpart else "")
        writer.writerow([
            timezone.localtime(txn.created_at).strftime('%H:%M:%S') if txn.created_at else "",
            txn.account.name,
            txn.get_transaction_type_display(),
            f"{txn.amount:.2f}",
            f"{txn.balance_after:.2f}",
            txn.description,
            txn.reference_no,
            link_str,
            txn.created_by.username if txn.created_by else "",
        ])

    return response

@login_required
def export_monthly_summary_csv(request):
    denied = _staff_access_required(request, "reports_financial")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    period = resolve_monthly_summary_period(request)
    context = get_monthly_summary_context(
        period['start_of_period'],
        period['end_of_period'],
        period['start_date_str'],
        period['end_date_str'],
        preset=period['preset'],
        show_jobs='',
        workspace=getattr(request, 'current_workspace', None),
    )

    def money(value):
        return f"{(value or Decimal('0.00')):.2f}"

    filename = f"financial_summary_{period['start_date_str']}_to_{period['end_date_str']}.csv"
    response = HttpResponse(content_type='text/csv')
    response['Content-Disposition'] = f'attachment; filename="{filename}"'

    writer = csv.writer(response)
    writer.writerow(['Financial Summary Report'])
    writer.writerow(['Period', f"{period['start_date_str']} to {period['end_date_str']}"])
    writer.writerow(['Basis', 'Closed jobs only for financial totals'])
    writer.writerow(['Unclaimed / Ready Basis', 'All-time jobs with Completed or Ready for Pickup status'])
    writer.writerow([])
    writer.writerow(['Job Statistics'])
    writer.writerow(['Jobs Created', context['jobs_created_count']])
    writer.writerow(['Jobs Closed', context['jobs_closed_count']])
    writer.writerow(['Current Month In Jobs Closed', context['current_month_in_closed_count']])
    writer.writerow(['Previous Month In Jobs Closed', context['previous_month_in_closed_count']])
    writer.writerow(['All-time Unclaimed / Ready Jobs', context['pending_completed_count']])
    writer.writerow(['All-time Unclaimed / Ready Value', money(context['pending_completed_value'])])
    writer.writerow(['All-time Ready for Pickup Jobs', context['ready_for_pickup_count']])
    writer.writerow(['All-time Ready for Pickup Value', money(context['ready_for_pickup_value'])])
    writer.writerow(['Returned -> Closed Jobs', context['jobs_returned_count']])
    writer.writerow(['Closed Vendor Jobs', context['vendor_jobs_count']])
    writer.writerow([])

    writer.writerow(['Closed Job Source Split'])
    writer.writerow(['Source', 'Revenue', 'Expense', 'Profit'])
    writer.writerow([
        'Current Month In Jobs Closed',
        money(context['current_month_in_closed_revenue']),
        money(context['current_month_in_closed_expense']),
        money(context['current_month_in_closed_profit']),
    ])
    writer.writerow([
        'Previous Month In Jobs Closed',
        money(context['previous_month_in_closed_revenue']),
        money(context['previous_month_in_closed_expense']),
        money(context['previous_month_in_closed_profit']),
    ])
    writer.writerow([])

    writer.writerow(['Closed Job Financial Summary'])
    writer.writerow(['Closed Revenue', money(context['overall_revenue'])])
    writer.writerow(['Closed Expense', money(context['overall_expense'])])
    writer.writerow(['Closed Profit', money(context['overall_profit'])])
    writer.writerow(['Overall Margin %', f"{(context['overall_margin'] or Decimal('0.00')):.2f}"])
    writer.writerow(['Gross Revenue Before Discount', money(context['closed_gross_revenue'])])
    writer.writerow(['Total Customer Discounts', money(context['total_discounts'])])
    writer.writerow(['Closed Bill Total', money(context['closed_receivable_bill_total'])])
    writer.writerow(['Closed Bill Paid', money(context['closed_receivable_paid'])])
    writer.writerow(['Closed Bill Balance', money(context['closed_receivable_balance'])])
    writer.writerow(['Shop Overhead Expenses (Period)', money(context.get('period_overhead_expenses', Decimal('0.00')))])
    writer.writerow(['True Net Operating Profit', money(context.get('period_net_profit', context['overall_profit']))])
    writer.writerow([])

    writer.writerow(['Closed Job Financial Blocks'])
    writer.writerow(['Block', 'Basis', 'Revenue', 'Expense', 'Profit'])
    for block in context['closed_financial_blocks']:
        writer.writerow([
            block['label'],
            block['note'],
            money(block['revenue']),
            money(block['expense']),
            money(block['profit']),
        ])
    writer.writerow([])

    writer.writerow(['Stock Sales Summary'])
    writer.writerow(['Units Sold', context['stock_sales_units']])
    writer.writerow(['Sale Lines', context['stock_sale_lines_count']])
    writer.writerow(['Unique Products', context['stock_products_count']])
    writer.writerow(['Average Sale Value', money(context['stock_avg_sale_value'])])
    writer.writerow([])

    writer.writerow(['Product-wise Stock Sales'])
    writer.writerow(['Product', 'SKU', 'Category', 'Units Sold', 'Sale Lines', 'Avg Unit Price', 'Revenue', 'COGS', 'Profit'])
    for product_row in context['stock_products_breakdown']:
        writer.writerow([
            product_row['name'],
            product_row['sku'],
            product_row['category'],
            product_row['units_sold'],
            product_row['sale_lines'],
            money(product_row['average_unit_price']),
            money(product_row['revenue']),
            money(product_row['cogs']),
            money(product_row['profit']),
        ])

    return response

@login_required
def print_monthly_summary_pdf(request):
    denied = _staff_access_required(request, "reports_financial")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    period = resolve_monthly_summary_period(request)
    context = get_monthly_summary_context(
        period['start_of_period'],
        period['end_of_period'],
        period['start_date_str'],
        period['end_date_str'],
        preset=period['preset'],
        show_jobs='',
    )
    context['pdf_layout'] = True
    return render(request, 'job_tickets/print_monthly_summary_pdf.html', context)

# in job_tickets/views.py

@login_required
def staff_technician_reports(request):
    # only staff allowed
    denied = _staff_access_required(request, "reports_technician")
    if denied:
        return denied
    if not user_can_view_financial_reports(request.user):
        return redirect('unauthorized')

    # get all technicians
    current_workspace = getattr(request, 'current_workspace', None)
    techs = list(
        scope_to_workspace(TechnicianProfile.objects, current_workspace)
        .select_related('user')
        .all()
    )

    # Use aggregated DB queries instead of N+1 Python loops
    from django.db.models import Count, Sum, DecimalField
    from django.db.models.functions import Coalesce

    tech_stats = TechnicianProfile.objects.filter(
        id__in=[t.id for t in techs]
    ).annotate(
        completed_count=Count(
            'jobticket',
            filter=Q(jobticket__status='Completed'),
            distinct=True,
        ),
        parts_total=Coalesce(
            Sum(
                'jobticket__service_logs__part_cost',
                filter=Q(
                    jobticket__status='Completed',
                ) & ~Q(jobticket__service_logs__description__icontains='Specialized Service'),
                output_field=DecimalField(),
            ),
            Decimal('0.00'),
        ),
        service_total=Coalesce(
            Sum(
                'jobticket__service_logs__service_charge',
                filter=Q(
                    jobticket__status='Completed',
                ) & ~Q(jobticket__service_logs__description__icontains='Specialized Service'),
                output_field=DecimalField(),
            ),
            Decimal('0.00'),
        ),
    )
    stats_map = {s.id: s for s in tech_stats}
    tech_user_ids = [t.user_id for t in techs if t.user_id]
    direct_stock_qs = scope_to_workspace(
        InventoryEntry.objects.filter(
            entry_type__in=['sale', 'sale_return'],
            job_ticket__isnull=True,
            bill__is_reversed=False,
        ).filter(
            Q(created_by_id__in=tech_user_ids) | Q(bill__created_by_id__in=tech_user_ids)
        ),
        current_workspace,
    ).values('created_by_id', 'bill__created_by_id', 'entry_type', 'total_amount')

    tech_stock_map = defaultdict(lambda: Decimal('0.00'))
    for entry in direct_stock_qs:
        uid = entry['created_by_id'] or entry['bill__created_by_id']
        if not uid:
            continue
        amt = entry['total_amount'] or Decimal('0.00')
        if entry['entry_type'] == 'sale':
            tech_stock_map[uid] += amt
        elif entry['entry_type'] == 'sale_return':
            tech_stock_map[uid] -= amt

    tech_rows = []
    for tech in techs:
        s = stats_map.get(tech.id, tech)
        completed_count = getattr(s, 'completed_count', 0) or 0
        parts_total = getattr(s, 'parts_total', Decimal('0.00')) or Decimal('0.00')
        stock_total = tech_stock_map.get(tech.user_id, Decimal('0.00'))
        service_total = getattr(s, 'service_total', Decimal('0.00')) or Decimal('0.00')
        total_sales = parts_total + stock_total + service_total
        is_active = getattr(tech.user, 'is_active', True)

        # Disabled technicians do not show up unless not zero
        if not is_active and completed_count == 0 and total_sales <= Decimal('0.00'):
            continue

        tech_rows.append({
            'tech': tech,
            'completed_count': completed_count,
            'parts_total': parts_total,
            'stock_total': stock_total,
            'service_total': service_total,
            'is_disabled': not is_active,
        })

    return render(request, 'job_tickets/staff_technician_reports.html', {'tech_rows': tech_rows})

@login_required
def daily_jobs_report(request, date_str, filter_type):
    access = get_staff_access(request.user)
    if not request.user.is_staff or not access.get("reports_overview"):
        return redirect('unauthorized')

    try:
        report_date = datetime.strptime(date_str, '%Y-%m-%d').date()
    except ValueError:
        messages.error(request, "Invalid date format provided.")
        return redirect('reports_dashboard')

    titles = {'in': 'Created', 'out': 'Closed', 'completed': 'Completed'}
    if filter_type not in titles:
        messages.error(request, "Invalid filter type provided.")
        return redirect('reports_dashboard')
    jobs_queryset = get_daily_report_jobs(
        report_date, filter_type, getattr(request, 'current_workspace', None),
    ).order_by('-created_at')
    report_title = f"Jobs {titles[filter_type]} On {date_str}"

    jobs = list(jobs_queryset.select_related('assigned_to__user').prefetch_related('service_logs'))
    calculate_job_totals(jobs)
    for job in jobs:
        job.discount_total = _money_or_zero(job.discount_amount)
        job.net_total = _net_amount_after_discount(job.total, job.discount_total)

    context = {
        'jobs': jobs,
        'report_title': report_title,
    }
    return render(request, 'job_tickets/daily_jobs_report.html', context)
