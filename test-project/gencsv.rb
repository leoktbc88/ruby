# Used for Award Intrepreter to calculate dollar value
  def generate_paygroup_csv pay_group, pay_run_detail
    require 'csv'

    category = self.category

    # preload the common payroll_codes
    normal_payroll_code = ShiftType.find_by_name("Normal").payroll_code  # "01"
    cover_payroll_code = ShiftType.find_by_name("Cover").payroll_code    # "00"
    ot_payroll_code = ShiftType.find_by_name("Overtime").payroll_code    # "1"
    pam_allowances_only_code = ShiftType.find_by_name("Allowances Only (pay as master)").payroll_code    # "99"

    # some awards have extra conditions
    r7_sta_emp_type_codes = EmployeeType.where("award_id in (?)", R7_STA_AWARD_IDS).pluck(:code)
    driver_mentor_emp_type_codes = EmployeeType.where(award_id: 15).pluck(:code) # Busways Driver Mentor EA

    # slr (sick leave relief) depots
    slr_depot_ids = HsaDepot.where("code in (?)", SICK_LEAVE_RELIEF_ALLOWANCE_DEPOTS).pluck(:id)
    slr_line_group_ids = LineGroup.where("code = ? AND hsa_depot_id in (?)", "SLR", slr_depot_ids).pluck(:id)
    slr_weekly_max = {}

    if INCLUDE_MAKE_UP_MINS
      headers = [
        "CON_ID", "SHIFT_NUMBER", "EMPLOYEE_NO", "SHIFT_DATE", "MEALTIMEMINS",
        "START_TIME_HHMM", "END_TIME_HHMM", "AMENITY_ALLOW",
        "MEAL_ALLOW", "TRAINER_ALLOW", "BENDY_ALLOW", "TOILET_ALLOW", "MAKEUPHRS"
      ]
    else
      # don't include 13th column
      headers = [
        "CON_ID", "SHIFT_NUMBER", "EMPLOYEE_NO", "SHIFT_DATE", "MEALTIMEMINS",
        "START_TIME_HHMM", "END_TIME_HHMM", "AMENITY_ALLOW",
        "MEAL_ALLOW", "TRAINER_ALLOW", "BENDY_ALLOW", "TOILET_ALLOW", "CALL_OUT_ALLOW",
        "SCHOOL_COMM_ALLOW", "THREE_DOOR_ALLOW", "REST_ALLOW", "SICK_LEAVE_RELIEF_ALLOW"
      ]
    end

    make_up_short_pay_groups = Rails.application.config.payroll_make_up_short_mins.keys.map{|pg| pg.to_i}
    make_up_short_mins = make_up_short_pay_groups.include?(pay_group.id) ? true : false

    # Generate the filename eg. SR_20171023_Blacktown_North.csv
    # NB if the file naming convention changes, make sure to also update the check_rules method in actual_lines_controller
    run_date_str = pay_run_detail["part_of_run"].gsub("-", "")
    filename = "SR_" + run_date_str + "_" + pay_group.name.gsub(" PL", "").gsub(" ", "_") + ".csv"

    # get all the lines applicable to this paygroup
    # we order so that when we use unfinalise feature it is easier for payroll to manually compare csv files if need be
    lines = ActualLine.joins(:actual_roster)
      .where("roster_headers.start_date = ?
        AND (actual_lines.employee ->> 'pay_group')::int = ?",
        self.start_date, pay_group.id).order(:row, :emp_code)
    csv_entries = []

    # setup the full time and part time emps to track the weekly hours
    full_time_emps, part_time_emps = {}, {}

    # create the directory to hold the file
    # NB if the payroll_folder path changes, make sure to also update the check_rules method in actual_lines_controller
    directory_date = pay_run_detail["part_of_run"].gsub("-", "")
    payroll_folder = "#{Rails.root}/downloads/payroll/#{directory_date}"

    lines.each do |line|
      # get the employee which will be used for all shifts
      if line.emp_code.blank?
        # no employee, skip this line
        puts "Skipping line #{line.row} for batch_id #{line.batch_id} as this line has no employee assigned to it"
        next
      else
        sunday_date = line.actual_roster.start_date.sunday.strftime("%d-%b-%y")
        employee_no = line.emp_code
        slr_check_needed = false
        if slr_line_group_ids.include?(line.line_group_id) && category == "Drivers"
          slr_check_needed = true
          slr_weekly_max[employee_no] = {line.batch_id => {}}
        end
      end

      # confirm that this employee is a driver and should have their
      # roster exported by shifts and rosters
      # NB we are exporting timesheets for all employee types in SA and R7
      employee = Employee.find_by_code(employee_no)
      unless (EMP_TYPE_DVR + EMP_TYPE_WORKSHOPS + EMP_TYPE_CLNR).include?(employee.employee_type.code) || [19, 20, 22, 23].include?(employee.hsa_depot_id)
        puts "Skipping line #{line.row} for batch_id #{line.batch_id} as this employee type is NOT exported through shifts and rosters"
        next
      end

      if make_up_short_mins
        if EMP_TYPE_FT_DRIVERS.include?(employee.employee_type.code)
          full_time_emps[employee_no] = {"sunday_date" => sunday_date, "total_mins" => line.total['total_mins']}
        elsif EMP_TYPE_PT_DRIVERS.include?(employee.employee_type.code)
          part_time_emps[employee_no] = {"sunday_date" => sunday_date, "total_mins" => line.total['total_mins']}
        end
      end

      # toilet allowance is limited to one per week
      toilet_allowance = false

      cert_req_day_threshold = line.hsa_depot.roster_config.dig("no_leave_cert_threshold", "value") || 2
      no_ph_pay_threshold = line.hsa_depot.roster_config.dig("no_ph_pay_threshold", "value") || 7

      DAYS.each do |day|
        # determine if we will use the actual shifts worked OR if we should
        # use the payroll overwrite shifts (ie pay as master roster)
        # NB if pay as master roster is turned on, then setting is applied across
        # depots and the driver should not be paid for shifts done at other depots
        payroll_overwrite = nil
        if !line.payroll_overwrite.nil? && !line.payroll_overwrite[day].nil?
          shifts = line.payroll_overwrite[day]["shifts"]
          payroll_overwrite = true
        else
          if line.linked_lines
            # see if any of the linked lines have pay as master turned on.
            # if yes do not use those shifts
            line.linked_lines.each do |ll|
              link = ActualLine.find_by_id(ll)
              unless link.blank?
                if !link.payroll_overwrite.nil? && !link.payroll_overwrite[day].nil?
                  payroll_overwrite = true
                  shifts = []
                  break
                end
              end
            end
            unless payroll_overwrite
              shifts = line["#{day}_final"] || line["#{day}_alt"] || line["#{day}_shift"]
              payroll_overwrite = false
            end
          else
            shifts = line["#{day}_final"] || line["#{day}_alt"] || line["#{day}_shift"]
            payroll_overwrite = false
          end
        end

        r7_sta_emp = r7_sta_emp_type_codes.include?(line.employee["position_code"])
        driver_mentor_emp = driver_mentor_emp_type_codes.include?(line.employee["position_code"])
        higher_duty_shift_type = nil

        if r7_sta_emp && shifts.present?
          # check if there are any higher duty yard/shed shifts on the day
          if (shifts.pluck("type") & HIGHER_DUTY_PAY_TYPES).present?
            # higher duty pay rate only applies if the higher duty work is not the only unrostered work for the day
            # e.g. if a driver does their regular driving shift but is then given higher duty yard work as OT, only the OT is paid at the higher rate
            # for all other scenarios, the whole day is paid at the highest rate
            higher_duty_shifts = shifts.select{|sh| HIGHER_DUTY_PAY_TYPES.include?(sh["type"])}
            if higher_duty_shifts.pluck("rostered").include?(true) || !shifts.select{|sh| !NOT_AVAILABLE_TYPE.include?(sh["type"])}.pluck("rostered").include?(true)
              # at least one higher duty shift on the day is rostered
              # or all work on the day is unrostered
              # pay as the highest rate - this is currently Higher Duty Yard (93)
              higher_duty_shift_type_id = higher_duty_shifts.pluck("type").include?(93) ? 93 : 92
              higher_duty_shift_type = ShiftType.find(higher_duty_shift_type_id)
            end
          end # if (shifts.pluck("type") & HIGHER_DUTY_PAY_TYPES).present?
        end # if r7_sta_emp && shifts.present?

        rows_to_add = []

        # AMENITY_ALLOW, MEAL_ALLOW, TRAINER_ALLOW, BENDY_ALLOW, SCHOOL_COMM_ALLOW are the allowances
        # paid on top of the shift, stored in a hash in the shift JSON
        # the following allowances are limited to one per day
        # toilet allowance is limited to one per week and is declared further up
        amenity_allowance = false
        trainer_allowance = false
        bendy_allowance = false
        non_driving_meal_allowance = false # meal allowance for non-driving rosters (driving rosters can have > 1)
        sick_leave_relief_allow = 0

        # loop through the shifts for the day
        # (shifts.to_a protects against shifts being nil)
        shifts.to_a.sort{|s| s["delta"]}.each do |shift|
          # skip leave for imported drivers
          next if line.employee.key?("other_depot_code") && LEAVE_TYPES.include?(shift["type"])
          # skip NOT_AVAILABLE_TYPE which is not sent to payroll
          next if NOT_AVAILABLE_TYPE.include?(shift["type"])

          # CON_ID ie payroll code. This is found using the shift type on This
          # shift then looked up in the shift_type table with a few exceptions
          # 1. If these shifts have come from payroll_overwrite then they must
          #   be rostered "01"
          # 2. If the shift is a yard/admin/c19 driving shift, SA special events
          #   then we also need to take the rostered flag into account as it could translate to either "01" or "00"
          # 3. NB HARDCODE in the Northcoast Pay Group, we will treat shift types
          #  (5,6,7,8) (all the training types) as type (5) ie all Northcoast training
          #  will be sent to payroll as payroll code "22"
          # 4. NB HARDCODE Special events (type 35 and 36) can be one of four payroll codes
          # 300 - Special Event UNROSTERED with NO ATTENDANCE ALLOWANCE
          # 301 - Special Event UNROSTERED with ATTENDANCE ALLOWANCE
          # 310 - Special Event ROSTERED with NO ATTENDANCE ALLOWANCE
          # 311 - Special Event ROSTERED with ATTENDANCE ALLOWANCE
          # 5. PH Rostered + Linked Lines. If a shift is type PH Rostered (31) AND
          # this line has a linked line AND the driver has done an unrostered
          # shift at the depot on this public holiday day, then we will ignore
          # the shift and not send it to payroll NB DONT PAY THIS SHIFT
          # 6. NB HARDCODE Rail charters (type 25) can be one of two payroll codes
          # 300 - UNROSTERED with NO attendance allowance
          # 310 - ROSTERED with NO attendance allowance
          # 7. NB Do not send through shifts with payroll_code f
          # f - currently used for other depot work and unpaid charters
          # 8. NB SA only - Higher Duties/Buddy Training
          # 49 - Rostered (01 if in the Adelaide Admin pay group)
          # 490 - Unrostered (00 if in the Adelaide Admin pay group)
          # 9. everything else use the payroll_code from shift_types table
          # 67 - Workers Compensation - Suitable Duties (force 01 for perms, 00 for casuals)
          # 10. NB OT with the reason code No Standing Type (55) will have pay code "14"
          # 11. NB Charters and training for STA award are either rostered "01" or unrostered "00"
          # 11b.   Training shift types for Driver Mentor award are either rostered "01" or unrostered "00"
          # 12. NB If higher_duty_shift_type has been set above, all shifts are converted to that type
          # 46 - Higher Duty Shed (rostered)
          # 460 - Higher Duty Shed (unrostered)
          # 47 - Higher Duty Yard (rostered)
          # 470 - Higher Duty Yard (unrostered)
          # 13. NB OT with reason code Filling Out Report (37) will have pay code "4"
          # - This applies to the R7 STA award only
          if payroll_overwrite
            # exception 1
            con_id = normal_payroll_code
          elsif higher_duty_shift_type.present?
            # exception 12
            con_id = higher_duty_shift_type.payroll_code
            con_id += "0" if !shift["rostered"]
          else
            shift_type = ShiftType.find(shift["type"])

            if shift_type.alt_duty_flag
              # exception 2
              con_id = shift["rostered"] ? normal_payroll_code : cover_payroll_code
            elsif pay_group.name.eql?("North Coast PL") && [5,6,7,8].include?(shift["type"])
              # exception 3
              con_id = "22"
            elsif [5, 6, 23, 25, 35, 36].include?(shift["type"]) && r7_sta_emp
              # exception 11 - no charter/training for STA award
              con_id = shift["rostered"] ? "01" : "00"
            elsif [5, 6].include?(shift["type"]) && driver_mentor_emp
              # exception 11b - no training for driver mentor award
              con_id = shift["rostered"] ? "01" : "00"
            elsif [25,35,36].include?(shift["type"])
              # exception 4
              if [25,35].include?(shift["type"]) && shift["rostered"]
                con_id = "310"
              elsif [25,35].include?(shift["type"]) && !shift["rostered"]
                con_id = "300"
              elsif shift["type"].eql?(36) && shift["rostered"]
                con_id = "311"
              elsif shift["type"].eql?(36) && !shift["rostered"]
                con_id = "301"
              end
            elsif shift_type.payroll_code == "f"
              next
            elsif [50, 51].include?(shift["type"])
              # exception 8
              if pay_group.name == "Adelaide Admin"
                con_id = shift["rostered"] ? "01" : "00"
              else
                con_id = shift["rostered"] ? "49" : "490"
              end
            elsif [67].include?(shift["type"])
              # Workers Compensation - Suitable Duties (force 01 for perms, 00 for casuals)
              con_id = EMP_TYPE_CASUAL.include?(employee.employee_type.code) ? "00" : "01"
            elsif HIGHER_DUTY_PAY_TYPES.include?(shift["type"])
              # exception 12
              con_id = shift["rostered"] ? shift_type.payroll_code : "#{shift_type.payroll_code}0"
            else
              if shift["type"].eql?(31) && !line.linked_lines.blank?
                # exception 5
                other_line_found = false
                line.linked_lines.each do |ll|
                  other_line = ActualLine.find(ll)
                  other_day = other_line["#{day}_final"] || other_line["#{day}_alt"] || other_line["#{day}_shift"]
                  unless other_day.blank?
                    other_line_found = true
                    break
                  end
                end
                next if other_line_found
              end
              # just use the regular payroll code
              con_id = shift_type.payroll_code
            end
          end # if payroll_overwrite

          if HrEvent::CERT_REQ_LEAVE_TYPES.include?(shift["type"]) && !LEAVE_CERT_EXCLUDED_DEPOTS.include?(employee.hsa_depot.code)
            # employees can have a certain number of days of CERT_REQ_LEAVE_TYPES leave
            # per year (from service start date) without providing a certificate
            # after that, leave of CERT_REQ_LEAVE_TYPES will be converted to Absent (79)
            current_date = (self.start_date + DAYS.index(day)).strftime("%Y%m%d").to_i
            current_leave = LeaveHistory.find_by(leave_date: current_date, user_id: employee.user_id)
            if current_leave.blank?
              raise StandardError.new "Could not find leave history entry for #{employee.code} on #{day}. Try refreshing the roster and finalising again, or contact the IT helpdesk if the error persists."
            elsif current_leave.certificate_type.blank?
              # we only want to convert this leave if there is no certificate
              year_start = employee.service_start_date.change(year: Date.today.year)
              if year_start > Date.today
                year_start -= 1.year
              end
              year_start = year_start.strftime("%Y%m%d").to_i
              leave_without_cert = LeaveHistory.where("leave_date >= ? and leave_date < ? and
                user_id = ? and certificate_type is null", year_start, current_date, employee.user_id)
              con_id = "79" if leave_without_cert.length >= cert_req_day_threshold
            end
          end

          if PH_TYPES.include?(shift["type"])
            # if the driver has been absent or on unpaid leave for at least no_ph_pay_threshold days
            # in the days leading up to this PH, the PH is not paid out
            # empty days and PH days are included as long as all other days are leave
            absence_count = 0
            empty_days_count = 0
            prev_day = day == "mon" ? "sun" : DAYS[DAYS.index(day) - 1]
            prev_line = line
            while absence_count <= no_ph_pay_threshold && empty_days_count <= no_ph_pay_threshold
              prev_line = prev_line.prev_week_line_by_user_id if prev_day == "sun"
              if prev_line.present?
                prev_shifts = prev_line.shifts_on_day(prev_day, {"utilise_linked_lines" => true, "keep_other_depot_shift_types" => true})
                if prev_shifts.blank?
                  # skip empty days but keep track of them so the loop doesn't continue forever
                  empty_days_count += 1
                elsif (prev_shifts.pluck("type") - (UNPAID_LEAVE_TYPES + PH_TYPES)).blank?
                  absence_count += 1
                else
                  break
                end
              else
                break
              end
              prev_day = prev_day == "mon" ? "sun" : DAYS[DAYS.index(prev_day) - 1]
            end # while absence_count <= no_ph_pay_threshold
            con_id = "79" if absence_count > no_ph_pay_threshold
          end # if PH_TYPES.include?(shift["type"])

          # SHIFT_NUMBER is the shift number worked by the employee. In any case
          # where the shift number is not a valid number/charter, '-1' is sent
          # in its place.
          shift_number = SPECIAL_SHIFT_NO.include?(shift["shift"]) ? -1 : shift["shift"]

          # EMPLOYEE_NO is the employee's code which we already stored above

          # SHIFT_DATE is the date in which the shift was worked, shifts that run
          # over midnight use the date the shift started
          shift_date = (line.actual_roster.start_date + DAYS.index(day)).strftime("%d-%b-%y")

          # MEALTIMEMINS is the number of minutes the driver took of UNPAID rest
          # time during the shift

          if SPECIAL_SHIFT_NO.include?(shift["shift"])
            next_day = shift["next_day"] == true
            overnight = next_day || shift["overnight"] == true
            start_min = shift["start_min"] || GeneralLibrary.get_minutes(shift["start"], next_day)
            end_min = shift["finish_min"] || GeneralLibrary.get_minutes(shift["finish"], overnight)
            shift_data = {"sd_time": {"start": shift["start"], "start_min": start_min},
              "fd_time": {"finish": shift["finish"], "finish_min": end_min},
              "meal_breaks": {"meal_a": {}, "meal_b": {}} }.as_json
          else
            if payroll_overwrite
              # get the shift from the master roster in case the actual shift was modified or deleted
              shift_data = MasterShift.find_by("batch_id": line.actual_roster.master_roster.batch_id,
                "shift": shift["shift"], "variant": shift["variant"])
            else
              shift_data = ActualShift.find_by("batch_id": line.batch_id, "shift": shift["shift"], "variant": shift["variant"])
            end
            start_min = shift["start_min"] || shift_data["sd_time"]["start_min"]
            end_min = shift["finish_min"] || shift_data["fd_time"]["finish_min"]
            next_day = shift.key?("next_day") ? shift["next_day"] : shift_data.sd_time["overnight"] == true
            overnight = shift.key?("overnight") ? shift["overnight"] : shift_data.fd_time["overnight"] == true
          end

          mealtimemins = 0
          meal_a = shift["meal_a"] || shift_data["meal_breaks"]["meal_a"]
          unless meal_a.blank?
            mealtimemins +=  (meal_a["end_min"] - meal_a["start_min"])
          end
          meal_b = shift["meal_b"] || shift_data["meal_breaks"]["meal_b"]
          unless meal_b.blank?
            mealtimemins +=  (meal_b["end_min"] - meal_b["start_min"])
          end

          # START_TIME_HHMM AND END_TIME_HHMM is the start and finish time
          # of the shift in 24H time
          start_time = Time.parse(shift["start"] || shift_data["sd_time"]["start"]).strftime("%H:%M")
          end_time = Time.parse(shift["finish"] || shift_data["fd_time"]["finish"]).strftime("%H:%M")
          duration_min = shift["duration_min"] || shift_data["hour_details"]["hours_min"]

          # if broken_break is present, split the shift into two lines
          create_extra_broken_row = false
          broken_break = shift["broken_break"] || shift_data["broken_break"] || {}
          if broken_break.present?
            broken_break = broken_break["broken_break"] if broken_break.key?("broken_break")
            bb_start = broken_break["start"]
            bb_start_min = broken_break["start_min"]
            bb_end = broken_break["end"]
            bb_end_min = broken_break["end_min"]
            broken_break = shift["broken_break"] || shift_data["broken_break"] || {}
            if bb_start && bb_end
              # prep the variables for second portion
              extra_broken_start = Time.parse(bb_end).strftime("%H:%M")
              extra_broken_start_overnight = bb_end_min >= 1440
              extra_broken_start_min = GeneralLibrary.get_minutes(extra_broken_start, extra_broken_start_overnight)
              extra_broken_end = end_time.deep_dup
              extra_broken_end_overnight = shift["overnight"] || shift_data["fd_time"]["overnight"]
              extra_broken_end_min = GeneralLibrary.get_minutes(extra_broken_end, extra_broken_end_overnight)
              # only set create_extra_broken_row to true if the duration would be > 0 minutes
              create_extra_broken_row = extra_broken_start_min < extra_broken_end_min
              # close off the first portion of the broken shift using the start time of the break
              end_time = Time.parse(bb_start).strftime("%H:%M")
              end_min = bb_start_min
              duration_min = GeneralLibrary.get_minutes(end_time) - GeneralLibrary.get_minutes(start_time)
            end
          end

          if shift["allowance"].blank? || (LEAVE_TYPES.include?(shift["type"]) && !r7_sta_emp)
            # allowances are only allowed on leave for R7 STA employees
            amenity_allow, meal_allow, trainer_allow, bendy_allow, toilet_allow, call_out_allow, school_comm_allow, three_door_allow, rest_allow, sick_leave_relief_allow = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            if slr_check_needed && !LEAVE_TYPES.include?(shift["type"]) && day != "sun"
              if !slr_weekly_max[employee_no][line.batch_id][day].present?
                if slr_weekly_max[employee_no][line.batch_id].length < 5 # max of 5 slr paid each week
                  if shift["rostered"] == true # mon-sat check rostered flag
                    slr_weekly_max[employee_no][line.batch_id][day] = 1
                    sick_leave_relief_allow = 1
                  end
                end
              end
            end
          else
            if r7_sta_emp && !EMP_TYPE_WORKSHOPS.include?(line.employee["position_code"])
              # employees under STA award only get bendy allowance
              # except STA workshops who also get toilet/meal allowances
              amenity_allow, meal_allow, trainer_allow, toilet_allow, call_out_allow, school_comm_allow, three_door_allow, rest_allow, sick_leave_relief_allow = 0, 0, 0, 0, 0, 0, 0, 0, 0
            else
              if shift["allowance"].dig("amenity","status").eql?("approved") && !amenity_allowance
                amenity_allow = 1
                amenity_allowance = true
              else
                amenity_allow = 0
              end
              if shift["allowance"].dig("meal","status").eql?("approved") && !non_driving_meal_allowance
                meal_allow = 1
                non_driving_meal_allowance = self.category != "Drivers"
              else
                meal_allow = 0
              end
              if shift["allowance"].dig("trainer","status").eql?("approved") && !trainer_allowance
                trainer_allow = 1
                trainer_allowance = true
              else
                trainer_allow = 0
              end
              if shift["allowance"].dig("toilet","status").eql?("approved") && !toilet_allowance
                toilet_allow = 1
                toilet_allowance = true
              else
                toilet_allow = 0
              end
              if shift["allowance"].dig("school_comm","status").eql?("approved")
                school_comm_allow = 1
              else
                school_comm_allow = 0
              end
              three_door_allow = 0
              if shift["allowance"].dig("rest_break","status").eql?("approved")
                rest_allow = shift["allowance"]["rest_break"]["allowance"]
              else
                rest_allow = 0
              end

              sick_leave_relief_allow = 0 # reset at shift level
              if slr_check_needed && !LEAVE_TYPES.include?(shift["type"]) && day != "sun"
                if !slr_weekly_max[employee_no][line.batch_id][day].present?
                  if slr_weekly_max[employee_no][line.batch_id].length < 5 # max of 5 slr paid each week
                    if shift["rostered"] == true # mon-sat check rostered flag
                      slr_weekly_max[employee_no][line.batch_id][day] = 1
                      sick_leave_relief_allow = 1
                    end
                  end
                end
              end
            end # unless r7_sta_emp

            call_out_allow = shift["allowance"].dig("call_out","status").eql?("approved") ? 1 : 0
            if shift["allowance"].dig("bendy","status").eql?("approved")
              # check if three door allowance should be used instead
              if r7_sta_emp && THREE_DOOR_ALLOWANCE_DEPOTS.include?(line.hsa_depot.code) && shift["allowance"].dig("bendy", "three_doors") == true
                if bendy_allowance
                  # bendy allowance has already been added to this day so don't add another one
                  # instead, check if the existing allowance needs to be replaced with three door allowance
                  bendy_allow = 0
                  existing_allowance = rows_to_add.find{|r| r[:bendy_allow] == 1 || r[:three_door_allow] == 1}
                  if existing_allowance[:three_door_allow] != 1
                    existing_allowance[:three_door_allow] = 1
                    existing_allowance[:bendy_allow] = 0
                  end
                else
                  bendy_allowance = true
                  three_door_allow = 1
                  bendy_allow = 0
                end
              elsif !bendy_allowance
                bendy_allowance = true
                bendy_allow = 1
              else
                bendy_allow = 0
              end
            else
              bendy_allow = 0
            end
          end

          # if this shift has any overtime, repeat the above process for the
          # overtime entry
          unless shift["overtime"].nil?
            shift["overtime"].each do |ot|
              if ot["status"].eql?("approved")
                ot_start_time = Time.parse(ot["start"]).strftime("%H:%M")
                ot_end_time = Time.parse(ot["end"]).strftime("%H:%M")

                ot_shift_date = ot["next_day"] ? (Date.parse(shift_date) + 1).strftime("%d-%b-%y") : shift_date

                if higher_duty_shift_type.present?
                  # exception 12
                  ot_con_id = higher_duty_shift_type.payroll_code + "0"
                elsif [50, 51].include?(shift["type"])
                  # exception 8
                  ot_con_id = "490"
                elsif ot["reason"] == "37" && r7_sta_emp
                  # exception 13 - Filling Out Report
                  ot_con_id = "4"
                elsif ot["reason"] == "55"
                  # exception 10 - No Standing Time
                  ot_con_id = "14"
                elsif [47].include?(shift["type"]) && employee.employee_type.award_id == 12
                  # COVID-19 Cleaning for Passenger Vehicle Transport Award only
                  # OT uses same payroll code as shift
                  ot_con_id = "2"
                else
                  ot_con_id = ot_payroll_code
                end
                # shift number is the same as this shift
                # employee is also the same
                # shift date is the same as this shift (even if it goes over midnight)
                # mealtimemins is always 0 for OT

                # NB there are no allowances for OT
                # add overtime to the CSV array
                if day == "sun" && ot["next_day"] && ot_con_id == ot_payroll_code && con_id == "00"
                  # if this is next day OT (not with a special pay code) on a Sunday
                  # attached to an unrostered shift (pay code 00 ONLY),
                  # we need to extend the previous shift instead of adding a separate OT line
                  # as it would otherwise end up on the Monday which could be outside of the pay period
                  # only extend the shift if the OT start time is within 1 minute of the shift end time
                  # any next day OT that doesn't fulfill all the criteria will have to be manually processed by payroll
                  if create_extra_broken_row
                    # extend the second portion of the broken shift
                    if (0..1).include?(GeneralLibrary.get_minutes(ot["start"]) - GeneralLibrary.get_minutes(extra_broken_end))
                      extra_broken_end = ot_end_time
                    end
                  else
                    # extend the shift itself
                    if (0..1).include?(GeneralLibrary.get_minutes(ot["start"]) - GeneralLibrary.get_minutes(end_time))
                      end_time = ot_end_time
                    end
                  end
                else
                  # add row for OT as normal
                  csv_entries << [ot_con_id, shift_number, employee_no, ot_shift_date, 0,
                    ot_start_time, ot_end_time, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                end # if day == "sun" && ot["next_day"] && ot_con_id == ot_payroll_code
              end # if ot["status"].eql?("approved")
            end # shift["overtime"].each
          end # unless shift["overtime"].nil?

          # don't add if duration < 0 (e.g. where broken break overlaps with start time)
          if duration_min > 0
            # if this is a shift that starts on the next day,
            # check if there is another shift of the same pay code that we can append this to
            # allow for a max. 1 minute gap between shifts
            if shift_data["sd_time"]["start_min"] >= 1440 && rows_to_add.present? && rows_to_add.any?{|row| row[:con_id] == con_id && [0,1].include?(row[:end_min] - shift_data["sd_time"]["start_min"])}
              row_to_update = rows_to_add.find{|row| [0,1].include?(row[:end_min] - shift_data["sd_time"]["start_min"])}
              row_to_update[:shift_no] += ", #{shift_number}"
              row_to_update[:end_time] = end_time
              row_to_update[:end_min] = shift_data["fd_time"]["finish_min"]
              row_to_update[:meal_min] += mealtimemins
              # add any allowances if applicable
              row_to_update[:amenity_allow] = 1 if amenity_allow == 1
              row_to_update[:meal_allow] = 1 if meal_allow == 1
              row_to_update[:trainer_allow] = 1 if trainer_allow == 1
              row_to_update[:bendy_allow] = 1 if bendy_allow == 1
              row_to_update[:toilet_allow] = 1 if toilet_allow == 1
              row_to_update[:call_out_allow] = 1 if call_out_allow == 1
              row_to_update[:school_comm_allow] = 1 if school_comm_allow == 1
              row_to_update[:three_door_allow] = 1 if three_door_allow == 1
              row_to_update[:rest_allow] = rest_allow if rest_allow > 0
              row_to_update[:sick_leave_relief_allow] = 1 if sick_leave_relief_allow == 1
            else
              # unrostered shifts that start on the next day and don't continue on
              # from an unrostered shift that starts before midnight should have their shift date
              # changed to the correct day UNLESS the original date was a Sunday
              if shift_data["sd_time"]["start_min"] >= 1440 && day != "sun" &&
                (!shift["rostered"] || UNROSTERED_TYPES.include?(shift["type"]))
                shift_date = (Date.parse(shift_date) + 1).strftime("%d-%b-%y")
              end
              rows_to_add << {con_id: con_id, shift_no: shift_number, emp_no: employee_no,
                shift_date: shift_date, meal_min: mealtimemins, start_time: start_time,
                start_min: start_min, end_time: end_time, end_min: end_min,
                amenity_allow: amenity_allow, meal_allow: meal_allow,
                trainer_allow: trainer_allow, bendy_allow: bendy_allow, toilet_allow: toilet_allow,
                call_out_allow: call_out_allow, school_comm_allow: school_comm_allow,
                three_door_allow: three_door_allow, rest_allow: rest_allow, sick_leave_relief_allow: sick_leave_relief_allow}
            end
          end # if duration_min > 0

          if create_extra_broken_row
            # NB broken shifts should never have the second portion starting after midnight,
            #    so don't bother changing shift_date here
            # don't double up on meal times or allowances here
            rows_to_add << {con_id: con_id, shift_no: shift_number, emp_no: employee_no,
              shift_date: shift_date, meal_min: 0, start_time: extra_broken_start,
              start_min: extra_broken_start_min, end_time: extra_broken_end, end_min: extra_broken_end_min,
              amenity_allow: 0, meal_allow: 0, trainer_allow: 0, bendy_allow: 0,
              toilet_allow: 0, call_out_allow: 0, school_comm_allow: 0, three_door_allow: 0, rest_allow: 0, sick_leave_relief_allow: 0}
          end
        end # shifts.to_a.each do |shift|

        rows_to_add.each do |row|
          csv_entries << [row[:con_id], row[:shift_no], row[:emp_no], row[:shift_date],
            row[:meal_min], row[:start_time], row[:end_time], row[:amenity_allow],
            row[:meal_allow], row[:trainer_allow], row[:bendy_allow], row[:toilet_allow],
            row[:call_out_allow], row[:school_comm_allow], row[:three_door_allow], row[:rest_allow], row[:sick_leave_relief_allow]]
        end

        # if this day was from payroll overwrite, we'll need to manually check
        # the original day for any allowances and overtime to add in. If allowances do exist,
        # we can send them through as a 0 minute line and AI will just add them
        # on the the remainder of the day. Overtime can be sent as normal
        # this includes shifts that have had their type change to overtime (3)
        # NB payroll overwrite isn't applicable to workshops rosters (AT THIS POINT)
        # NB 2020-03-03 total overtime duration for the day is combined and
        # added to the end of the last shift to prevent issues when actual shift + overtime
        # finishes before start of master shift
        if payroll_overwrite
          actual_shifts = line["#{day}_final"] || line["#{day}_alt"] || line["#{day}_shift"] || []
          day_allowances = {amenity: 0, meal: 0, trainer: 0, bendy: 0, toilet: 0,
            call_out: 0, school_comm: 0, three_door: 0, rest_break: 0, sick_leave_relief: 0}
          shift_date = (line.actual_roster.start_date + DAYS.index(day)).strftime("%d-%b-%y")
          overtime_duration = 0
          actual_shifts.each do |shift|
            if shift["allowance"]
              if shift["allowance"].dig("amenity","status").eql?("approved")
                day_allowances[:amenity] = 1
              end
              if shift["allowance"].dig("meal","status").eql?("approved")
                day_allowances[:meal] = 1
              end
              if shift["allowance"].dig("trainer","status").eql?("approved")
                day_allowances[:trainer] = 1
              end
              if shift["allowance"].dig("bendy","status").eql?("approved")
                day_allowances[:bendy] = 1
              end
              if shift["allowance"].dig("toilet","status").eql?("approved")
                day_allowances[:toilet] = 1
              end
              if shift["allowance"].dig("call_out","status").eql?("approved")
                day_allowances[:call_out] = 1
              end
              if shift["allowance"].dig("school_comm","status").eql?("approved")
                day_allowances[:school_comm] = 1
              end
              if shift["allowance"].dig("three_door","status").eql?("approved")
                day_allowances[:three_door] = 1
              end
              if shift["allowance"].dig("rest_break","status").eql?("approved")
                day_allowances[:rest_break] = shift["allowance"]["rest_break"]["allowance"]
              end
              # slr not needed for payroll_overwrite concept
              day_allowances[:sick_leave_relief] = 0
            end # if shift["allowance"]
            if UNROSTERED_TYPES.include?(shift["type"]) || shift["rostered"] == false
              ot_con_id = ot_payroll_code
              shift_number = SPECIAL_SHIFT_NO.include?(shift["shift"]) ? -1 : shift["shift"]
              if shift.key?("start")
                overnight = shift.key?("overnight") ? shift["overnight"] : false
                shift_start_min = GeneralLibrary.get_minutes(shift["start"])
                shift_finish_min = GeneralLibrary.get_minutes(shift["finish"], overnight)
                overtime_duration += shift_finish_min - shift_start_min
              else
                shift_data = ActualShift.find_by("batch_id": line.batch_id, "shift": shift["shift"], "variant": shift["variant"])
                overtime_duration += shift_data.fd_time["finish_min"] - shift_data.sd_time["start_min"]
              end
            end # UNROSTERED_TYPES.include?(shift["type"]) || shift["rostered"] == false
            unless shift["overtime"].blank?
              ot_con_id = ot_payroll_code
              shift["overtime"].each do |ot|
                if ot["status"].eql?("approved")
                  overtime_duration += ot["duration_min"]
                end
              end
            end # unless shift["overtime"].blank?
          end # actual_shifts.each
          if overtime_duration > 0
            ot_con_id = ot_payroll_code
            last_shift = csv_entries[-1]
            if last_shift[2] != employee_no || last_shift[3] != shift_date
              # employee's master roster does not have any shifts for this day
              # add overtime starting at 9AM
              ot_start_time = "09:00"
              ot_end_min = 540 + overtime_duration
              ot_end_time = GeneralLibrary.get_time(ot_end_min, true)
            else
              # overtime start is the end time of the last shift
              ot_start_time = last_shift[6]
              ot_start_min = GeneralLibrary.get_minutes(ot_start_time)
              ot_end_min = ot_start_min + overtime_duration
              ot_end_time = GeneralLibrary.get_time(ot_end_min, true)
            end
            # add overtime to the CSV array
            csv_entries << [ot_con_id, -1, employee_no, shift_date, 0,
              ot_start_time, ot_end_time, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
          end # if overtime_duration > 0
          if day_allowances.values.include?(1)
            csv_entries << ([pam_allowances_only_code, -1, employee_no, shift_date, 0,
              "00:00", "00:00"] + day_allowances.values)
          end
        end # if payroll_overwrite
      end # DAYS.each do |day|
    end # lines.each do |line|

    # get all the roster amendments for this payroll group and also add them
    # to the csv_entries array
    roster_amendments = RosterAmendment.joins(:actual_roster)
      .where("roster_headers.start_date = ?
        AND (roster_amendments.employee ->> 'pay_group')::int = ?",
        self.start_date, pay_group.id)

    # if this is week 2 of the fortnight, get make up entries from previous week
    # roster amendments may override make up pay from the previous week
    if lines[0].hsa_depot.pay_run_freq['freq'] == 'fortnight' && pay_run_detail['run_this_week'] == true && File.exists?("#{payroll_folder}/#{filename}.make_up")
      make_up_entries = CSV.read("#{payroll_folder}/#{filename}.make_up")
    else
      make_up_entries = []
    end

    roster_amendments.each do |amendment|
      # get the employee which will be used for this amendment
      if amendment.employee.blank?
        # no employee, skip this line
        puts "Skipping amendment #{amendment.id} for batch_id #{amendment.batch_id} as this amendment has no employee assigned to it"
        next
      else
        employee_no = amendment.employee["e_code"]
      end

      # confirm that this employee should have their roster exported by shifts and rosters
      employee = Employee.find_by_code(employee_no)
      unless employee.pay_group.active
        puts "Skipping amendment #{amendment.id} for batch_id #{amendment.batch_id} as the #{employee.pay_group.name} pay group is NOT exported through shifts and rosters"
        next
      end

      # con_id
      shift_type = ShiftType.find(amendment.shift_type["type"])
      if shift_type["alt_duty_flag"]
        con_id = amendment.shift_type["rostered"] ? normal_payroll_code : cover_payroll_code
      else
        con_id = shift_type.payroll_code
      end

      # shift number
      shift_number = "-1"

      # shift_date
      shift_date = amendment.date.strftime("%d-%b-%y")

      mealtimemins = 0
      unless amendment.meal_breaks["meal_a"].blank?
        mealtimemins += (amendment.meal_breaks["meal_a"]["end_min"] - amendment.meal_breaks["meal_a"]["start_min"])
      end
      unless amendment.meal_breaks["meal_b"].blank?
        mealtimemins += (amendment.meal_breaks["meal_b"]["end_min"] - amendment.meal_breaks["meal_b"]["start_min"])
      end

      # shift start/finish
      start_time = Time.parse(amendment.start_time["start"]).strftime("%H:%M")
      end_time = Time.parse(amendment.finish_time["finish"]).strftime("%H:%M")

      # shift allowances
      amenity_allow = amendment.allowances.nil? ? 0 : amendment.allowances.include?("AMENITY") ? 1 : 0
      meal_allow = amendment.allowances.nil? ? 0 : amendment.allowances.include?("MEAL") ? 1 : 0
      trainer_allow = amendment.allowances.nil? ? 0 : amendment.allowances.include?("TRAINER") ? 1 : 0
      bendy_allow = amendment.allowances.nil? ? 0 : amendment.allowances.include?("BENDY") ? 1 : 0
      toilet_allow = amendment.allowances.nil? ? 0 : amendment.allowances.include?("TOILET") ? 1 : 0

      # add the entries to the CSV array
      if pay_group.category.eql?("Workshops")
        con_id = "" if ["00","01","1","770","771"].include?(con_id) && !amendment.shift_type["type"].eql?(45)
      end

      # don't include 13th column
      csv_entries << [con_id, shift_number, employee_no, shift_date,
        mealtimemins, start_time, end_time, amenity_allow, meal_allow,
        trainer_allow, bendy_allow, toilet_allow]

      # if roster amendment was created for previous week, make_up_entries may need to be edited
      if make_up_short_mins
        fortnight_monday = Date.strptime(pay_run_detail['part_of_run'], '%Y-%m-%d') - 7
        fortnight_sunday = Date.strptime(pay_run_detail['part_of_run'], '%Y-%m-%d').sunday
        if fortnight_monday <= amendment.date && fortnight_sunday >= amendment.date
          if start_time != "00:00" && end_time != "00:00"
            start_mins = GeneralLibrary.get_minutes(start_time)
            if start_time > end_time
              end_mins = GeneralLibrary.get_minutes(end_time, true)
            else
              end_mins = GeneralLibrary.get_minutes(end_time)
            end
            ra_duration = GeneralLibrary.get_decimal((end_mins - start_mins), 'minutes', 4)
            make_up = make_up_entries.find{|m| m[2] == employee_no}
            if make_up.present?
              # deduct the roster amendment duration from the make up minutes
              make_up_mins = (make_up[12].to_f - ra_duration).round(4)
              make_up_index = make_up_entries.index(make_up)
              if make_up_mins <= 0
                # remove the entry entirely
                make_up_entries.delete_at(make_up_index)
              else
                # update the entry
                make_up_entries[make_up_index][12] = make_up_mins
              end
            end
          end
        end
      end

    end # roster_amendments.each do |amendment|

    if INCLUDE_MAKE_UP_MINS && make_up_short_mins
      # iterate and setup data for full time emps that don't meet the min 38 hrs / week
      full_time_emp_details = {}
      full_time_emps.each do |k, v|
        min_ft = 38 * 60
        if v['total_mins'] < min_ft
          full_time_emp_details[k] = {}
          full_time_emp_details[k]['total_mins'] = v['total_mins']
          full_time_emp_details[k]['make_up_mins'] = min_ft - v['total_mins']
          full_time_emp_details[k]['sunday_date'] = v['sunday_date']
        end
      end

      # iterate and setup data for part time emps that don't meet the min 25 hrs / week
      # only for school rosters
      part_time_emp_details = {}
      if self.roster_class == "S"
        part_time_emps.each do |k, v|
          min_pt = 25 * 60
          if v['total_mins'] < min_pt
            part_time_emp_details[k] = {}
            part_time_emp_details[k]['total_mins'] = v['total_mins']
            part_time_emp_details[k]['make_up_mins'] = min_pt - v['total_mins']
            part_time_emp_details[k]['sunday_date'] = v['sunday_date']
          end
        end
      end

      # add to csv the full time emps which fail to met the rules add make up minutes
      full_time_emp_details.each do |k, v|
        make_up_entries << [98, -1, k, v['sunday_date'], 0, "00:00", "00:00", 0, 0, 0, 0, 0, GeneralLibrary.get_decimal(v['make_up_mins'], 'minutes', 4)]
      end

      # add to csv the part time emps which fail to met the rules add make up minutes
      part_time_emp_details.each do |k, v|
        make_up_entries << [97, -1, k, v['sunday_date'], 0, "00:00", "00:00", 0, 0, 0, 0, 0, GeneralLibrary.get_decimal(v['make_up_mins'], 'minutes', 4)]
      end
    end # if make_up_short_mins

    # make the directory for this pay week
    if lines[0].hsa_depot.pay_run_freq['freq'] == 'fortnight' && !Dir.exist?(payroll_folder)
      FileUtils.mkdir_p(payroll_folder)
    else
      FileUtils.mkdir_p(payroll_folder)
    end

    # flag to indicate regenrated_payroll file specific to Unfinalise/Re finalise logic for fortnightly pay cycles
    regenerated_pay_file = false

    # finally save the CSV file
    if lines[0].hsa_depot.pay_run_freq['freq'] == 'week'
      CSV.open("#{payroll_folder}/#{filename}", "wb", :headers => headers, :write_headers => true, :row_sep=>"\r\n") do |csv|
        (csv_entries + make_up_entries).each do |entry| csv << entry end
      end
    elsif lines[0].hsa_depot.pay_run_freq['freq'] == 'fortnight'
      if pay_run_detail['run_this_week'] == true
        tmp_filename = filename + '.week2'
        # append make up pay to csv_entries
        csv_entries += make_up_entries
      else
        tmp_filename = filename + '.week1'
        # save make up entries to a separate file
        CSV.open("#{payroll_folder}/#{filename}.make_up", "wb", :row_sep=>"\r\n") do |csv|
          make_up_entries.each do |entry| csv << entry end
        end
      end
      CSV.open("#{payroll_folder}/#{tmp_filename}", "wb", :headers => headers, :write_headers => true, :row_sep=>"\r\n") do |csv|
        csv_entries.each do |entry| csv << entry end
      end

      # combine the two weeks into single file
      if pay_run_detail['run_this_week'] == true
        if File.exist?("#{payroll_folder}/#{filename}.week1")
          IO.copy_stream("#{payroll_folder}/#{filename}.week1", "#{payroll_folder}/#{filename}")
        else
          raise StandardError.new "We are missing the pay run file #{filename} for week 1 of this fortnight pay run, please contact IT for help."
        end
        system("sed '1d' #{payroll_folder}/#{tmp_filename} >> #{payroll_folder}/#{filename}")
      else
        # this section deals with week 1 rosters which were already finalised, then unfinalised and now finalised once more
        # and needed the main payroll file generated once more
        if self.sibling_rosters_all_finalised? && !File.exist?("#{payroll_folder}/#{filename}")
          if File.exist?("#{payroll_folder}/#{filename}.week1")
            IO.copy_stream("#{payroll_folder}/#{filename}.week1", "#{payroll_folder}/#{filename}")
          else
            raise StandardError.new "We are missing the pay run file #{filename} for week 1 of this fortnight pay run, please contact IT for help."
          end
          system("sed '1d' #{payroll_folder}/#{filename}.week2 >> #{payroll_folder}/#{filename}")
          regenerated_pay_file = true
        end
      end
    else
      # just in case we introduce other pay run freq and forget to update this method
      raise StandardError.new "Unable to finalise roster as pay run cycle logic for #{lines[0].hsa_depot.pay_run_freq.dig("freq")} is undefined"
    end

    # verify that the CSV has been saved to the server
    if lines[0].hsa_depot.pay_run_freq['freq'] == 'week' || pay_run_detail['run_this_week'] == true || regenerated_pay_file == true
      check_filename = "#{payroll_folder}/#{filename}"
    else
      check_filename = "#{payroll_folder}/#{filename}.week1"
    end

    csv_create_failed = false
    if Rails.application.config.payroll_file_skip_transfer != true
      1.upto(3) do |i|
        if File.exist?(check_filename)
          csv_create_failed = false
          return {filename: filename, roster_amendments: roster_amendments}
        else
          csv_create_failed = true
        end
        sleep(1)
      end
      if csv_create_failed == true
        raise Exceptions::MissingCsvFile.new("CSV file has NOT been successfully created")
      end
    else
      return {filename: filename, roster_amendments: roster_amendments}
    end
  end
