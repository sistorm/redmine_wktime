# ERPmine - ERP for service industry
# Copyright (C) 2011-2016  Adhi software pvt ltd
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class WkpayrollController < WkbaseController

	menu_item :wkattendance
	before_action :require_login
	before_action :check_perm_and_redirect, :only => [:edit, :user_salary_settings]
	before_action :check_admin_perm_and_redirect, :only => [:index]
	before_action :check_setting_admin_perm_and_redirect, :only => [:payrollsettings, :save_bulk_edit]

	include WkpayrollHelper
	include WktimeHelper
	include WkreportHelper

	def index
		payrollEntries()
		payrollEntriesArr = @payrollEntries.to_a
		@entry_count = @payrollEntries.length()
		@payrollEntries = Hash.new
		setLimitAndOffset()
		page_no = (params['page'].blank? ? 1 : params['page']).to_i
		from = @offset
		to = (@limit * page_no)

		payrollEntriesArr.each_with_index do |entry, index|
			index += 1
			if index > from && index <= to
				@payrollEntries[entry.first] = entry.last
			end
		end
		@total_gross = @payrollEntries.sum { |k, p| p[:BT] + p[:AT] }
		@total_net = @payrollEntries.sum { |k, p| p[:BT] + p[:AT] - p[:DT] }

	end

	def payrollEntries
		sort_init 'id', 'asc'
		sort_update 'user' => "CONCAT(U.firstname, U.lastname)",
					'salary_date' => "S.salary_date",
					'basic_pay' => "basic_pay",
					'allowances' => "allowances	",
					'deduction_total' => "deduction_total",
					'gross' => "gross",
					'net' => "net",
					'join_date' => "join_date"
		isGeneratePayroll = params[:generate]
		@isPreview = params[:generate].blank? ? false : !to_boolean(params[:generate])
		@total_gross = 0
		@total_net = 0
    	set_filter_session
    	retrieve_date_range
		userIds = getUsersAndGroups
		ids = nil
		user_id = session[controller_name].try(:[], :user_id)
		group_id = session[controller_name].try(:[], :group_id)
		
		if user_id.blank? || !validateERPPermission('A_TE_PRVLG')
		   ids = User.current.id
		elsif user_id.to_i != 0 && group_id.to_i == 0
		   ids = user_id.to_i
		elsif group_id.to_i != 0
			ids = user_id.to_i == 0 ? (userIds.blank? ? 0 : userIds.join(',')) : user_id.to_i
		else
		   ids = userIds.join(',')
		end

		unless isGeneratePayroll.blank?
			payrollAmount = generatePayroll(ids, @to +1, isGeneratePayroll)
		end
		
		unless isGeneratePayroll == "false"
			payrollAmount = get_wksalaries_in_hash_format(ids, nil)
		end

		form_payroll_entries(payrollAmount, ids)

	end

	def get_wksalaries_in_hash_format(userId, salaryDate)
		payrollAmount = Array.new
		sql_contd = " WHERE "

		if !salaryDate.blank?
			sql_contd += " S.salary_date = '#{salaryDate}' "
		elsif !@from.blank? && !@to.blank?
			sql_contd += " S.salary_date between '#{@from}' AND '#{@to}' "
		end

		unless userId.blank?
			sql_contd += " AND " if sql_contd != " WHERE "
			sql_contd += " S.user_id IN (#{userId}) "
		end
		orderSQL = (action_name == 'edit' || sort_clause.blank?)  ? "" : " ORDER BY "+ sort_clause.first
		payroll_salaries = WkSalary.find_by_sql("SELECT S.*, concat(U.firstname, U.lastname) AS user, (SAL.basic_pay + SAL.allowances) AS gross,
			((SAL.basic_pay + SAL.allowances) - SAL.deduction_total) AS net, WU.join_date
			FROM wk_salaries AS S
			INNER JOIN (
				SELECT S.user_id, S.salary_date, SUM(CASE WHEN SA.component_type = 'a' THEN S.amount ELSE 0 END) AS allowances,
					SUM(CASE WHEN SA.component_type = 'b' THEN S.amount ELSE 0 END) AS basic_pay,
					SUM(CASE WHEN SA.component_type = 'd' THEN S.amount ELSE 0 END) AS deduction_total
				FROM wk_salaries AS S
				INNER JOIN wk_salary_components AS SA ON SA.id = S.salary_component_id" + sql_contd +
				"GROUP BY S.user_id, S.salary_date
			) AS SAL ON S.user_id = SAL.user_id AND S.salary_date = SAL.salary_date
			LEFT JOIN users AS U ON U.id = S.user_id LEFT JOIN wk_users WU ON WU.user_id = U.id" + sql_contd + orderSQL)
		
		payroll_salaries.each do |entry|
			payrollAmount << {:user_id => entry.user_id, :component_id => entry.salary_component_id, :amount => (entry.amount).round, 
								:currency => entry.currency, :salary_date => entry.salary_date}
		end
	end

	def form_payroll_entries(payrollAmount, userId)
		usersDetails = User.joins("LEFT JOIN wk_users WU ON WU.user_id = users.id").where("users.id IN (#{userId})").select("users.*, WU.join_date")
		salaryComponents = WkSalaryComponents.all
		basic_Total = nil
		allowance_total = nil
		deduction_total = nil
		@payrollEntries = Hash.new

		payrollAmount.each do |payroll|
			key = payroll[:user_id].to_s + "_" + payroll[:salary_date].to_s
			if @payrollEntries[key].blank?
				@payrollEntries[key] = { :uID => payroll[:user_id], :firstname => nil, :lastname => nil, :joinDate => nil, :salDate => payroll[:salary_date], :BT => 0, :AT => 0, :DT => 0, :currency => nil, :details => {:b => [], :a => [], :d => []}}
			end

			usersDetails.each do |user|
				if payroll[:user_id] == user.id
					@payrollEntries[key][:firstname] = user.firstname
					@payrollEntries[key][:lastname] = user.lastname
					@payrollEntries[key][:joinDate] = user.join_date
				end
			end

			salaryComponents.each do |s_cmpt|
				if payroll[:salary_component_id] == s_cmpt.id
					@payrollEntries[key][:currency] = payroll[:currency]
					case s_cmpt.component_type
					when "b"
						@payrollEntries[key][:BT] = @payrollEntries[key][:BT].to_i + payroll[:amount].to_i
						@payrollEntries[key][:details][:b] << [s_cmpt.name, payroll[:amount].to_i, payroll[:currency]]
					when "a"
						@payrollEntries[key][:AT] = @payrollEntries[key][:AT].to_i + payroll[:amount].to_i
						@payrollEntries[key][:details][:a] << [s_cmpt.name, payroll[:amount].to_i, payroll[:currency]]
					when "d"
						@payrollEntries[key][:DT] = @payrollEntries[key][:DT] + payroll[:amount].to_i
						@payrollEntries[key][:details][:d] << [s_cmpt.name, payroll[:amount].to_i, payroll[:currency]]
					end
				end
			end
		end
	end

	def edit
		userid = params[:user_id]
		salarydate = params[:salary_date]
		key = userid.to_s + "_" + salarydate.to_s
		if to_boolean(params[:isPreview])
			payrollAmount = generatePayroll(userid, salarydate.to_date, "false")
		else
			payrollAmount = get_wksalaries_in_hash_format(userid, salarydate)
		end	
		form_payroll_entries(payrollAmount, userid)
		@payrollDetails = @payrollEntries[key][:details]
	end

	def updateUserSalary
		userId = params[:user_id]
		salary_comps = get_salary_components
		u_salary_comps = Array.new
		salary_comps.each do |component|
				componentId = component.id
				is_override = params['is_override' + componentId.to_s()]
				dependent_id = params['dependent_id' + componentId.to_s()].to_i
				factor = params['factor' + componentId.to_s()]
				u_salary_comps << {:user_id => userId, :component_id => componentId, :dependent_id => dependent_id, :factor => factor, :is_override => is_override}
			end
			errorMsg = saveUserSalary(u_salary_comps, false)	
			if errorMsg.nil?
				if params[:taxsettings].present?
						redirect_to :action => 'income_tax', action_type: 'userSettings', user_id: userId, method: 'saveTaxVal',
												 taxsettings: params[:taxsettings].permit!.to_h
				else
					redirect_to :action => 'usrsettingsindex'
					flash[:notice] = l(:notice_successful_update)
				end
			else
				flash[:error] = errorMsg
				redirect_to :action => 'user_salary_settings'
			end
	end
	
	def generatePayroll(userIds, salaryDate, isGeneratePayroll)
		errorMsg = generateSalaries(userIds,salaryDate, isGeneratePayroll)
		if to_boolean(isGeneratePayroll)
			if errorMsg.nil?
				redirect_to action: 'index' , tab: 'payroll'
				flash[:notice] = l(:notice_successful_update)		
			elsif !errorMsg.blank? &&  errorMsg == 1			
				flash[:notice] =  l(:label_salary) + " " +  l(:notice_successful_update) 
				if isChecked('salary_auto_post_gl')
					flash[:error] = l(:error_trans_msg)
				end
				redirect_to :action => 'index'
			end
		end
		payroll_list = @payrollList
	end

	def user_salary_settings
		userId = params[:user_id]
		sqlStr = getUserSalaryQueryStr
		sqlStr = sqlStr + "Where u.id = #{userId} and u.type = 'User'" +
		"order by u.id, sc.component_type"
		@userSalHash = getUserSalaryHash(userId, Date.today.at_end_of_month + 1)
		@userSalaryEntries = WkUserSalaryComponents.find_by_sql(sqlStr)
		getTaxSettingVal
	end

	def saveUsrSalCompHistory(userSalCompHash)
		wkHUserSalComp = WkHUserSalaryComponents.new
		userSalCompHash.each do |key, value|
			wkHUserSalComp[key] = value
		end
		wkHUserSalComp.save()
	end

	def getUserSettingHistoryHash(userSettingObj)
		hUserSettingHash = Hash.new
		hUserSettingHash['user_id'] = userSettingObj.user_id
		hUserSettingHash['user_salary_component_id'] = userSettingObj.id
		hUserSettingHash['salary_component_id'] = userSettingObj.salary_component_id
		hUserSettingHash['dependent_id'] = userSettingObj.dependent_id
		hUserSettingHash['factor'] = userSettingObj.factor
		hUserSettingHash['created_at'] = userSettingObj.created_at
		hUserSettingHash['updated_at'] = userSettingObj.updated_at 
		hUserSettingHash
	end
	
    def findBySql(query)
		result = WkSalary.find_by_sql("select count(*) as id from (" + query + ") as v2")
	    @entry_count = result.blank? ? 0 : result[0].id
	    setLimitAndOffset()		
	    rangeStr = formPaginationCondition()	
	    @payroll_entries = WkSalary.find_by_sql(query + rangeStr)
	end

	def setLimitAndOffset		
		if api_request?
			@offset, @limit = api_offset_and_limit
			if !params[:limit].blank?
				@limit = params[:limit]
			end
			if !params[:offset].blank?
				@offset = params[:offset]
			end
		else
			@entry_pages = Paginator.new @entry_count, per_page_option, params['page']
			@limit = @entry_pages.per_page
			@offset = @entry_pages.offset
		end	
	end
	
	def formPaginationCondition
		rangeStr = ""
		if ActiveRecord::Base.connection.adapter_name == 'SQLServer'				
			rangeStr = " OFFSET " + @offset.to_s + " ROWS FETCH NEXT " + @limit.to_s + " ROWS ONLY "
		else		
			rangeStr = " LIMIT " + @limit.to_s +	" OFFSET " + @offset.to_s
		end
		rangeStr
	end

	def set_filter_session
		session[controller_name] = {:from => @from, :to => @to} if session[controller_name].nil?
		if params[:searchlist] == controller_name
			filters = [:period_type, :period, :group_id, :user_id, :from, :to]
			filters.each do |param|
				if params[param].blank? && session[controller_name].try(:[], param).present?
					session[controller_name].delete(param)
				elsif params[param].present?
					session[controller_name][param] = params[param]
				end
			end
		end
   	end
   
   	def getMembersbyGroup
		group_by_users=""
		userList=[]
		userList = getGroupMembers
		userList.each do |users|
			group_by_users << users.id.to_s() + ',' + users.name + "\n"
		end
		respond_to do |format|
			format.text  { render :plain => group_by_users }
		end
	end	
	
   # Retrieves the date range based on predefined ranges or specific from/to param dates
	def retrieve_date_range
		@free_period = false
		@from, @to = nil, nil
		period_type = session[controller_name].try(:[], :period_type)
		period = session[controller_name].try(:[], :period)
		fromdate = session[controller_name].try(:[], :from)
		todate = session[controller_name].try(:[], :to)
		
		if (period_type == '1' || (period_type.nil? && !period.nil?)) 
		    case period.to_s
			  when 'today'
				@from = @to = Date.today
			  when 'yesterday'
				@from = @to = Date.today - 1
			  when 'current_week'
				@from = getStartDay(Date.today - (Date.today.cwday - 1)%7)
				@to = @from + 6
			  when 'last_week'
				@from =getStartDay(Date.today - 7 - (Date.today.cwday - 1)%7)
				@to = @from + 6
			  when '7_days'
				@from = Date.today - 7
				@to = Date.today
			  when 'current_month'
				@from = Date.civil(Date.today.year, Date.today.month, 1)
				@to = (@from >> 1) - 1
			  when 'last_month'
				@from = Date.civil(Date.today.year, Date.today.month, 1) << 1
				@to = (@from >> 1) - 1
			  when '30_days'
				@from = Date.today - 30
				@to = Date.today
			  when 'current_year'
				@from = Date.civil(Date.today.year, 1, 1)
				@to = Date.civil(Date.today.year, 12, 31)
	        end
		elsif period_type == '2' || (period_type.nil? && (!fromdate.nil? || !todate.nil?))
		    begin; @from = fromdate.to_s.to_date unless fromdate.blank?; rescue; end
		    begin; @to = todate.to_s.to_date unless todate.blank?; rescue; end
		    @free_period = true
		else
		  # default
		  # 'current_month'		
			@from = Date.civil(Date.today.year, Date.today.month, 1)
			@to = (@from >> 1) - 1
	    end    
		
		@from, @to = @to, @from if @from && @to && @from > @to

	end
	
  	def check_perm_and_redirect
	  unless check_permission
	    render_403
	    return false
	  end
	end
	
	def check_permission
		ret = false
		ret = params[:user_id].to_i == User.current.id
		return (ret || validateERPPermission('A_TE_PRVLG'))
	end
	
	def check_admin_perm_and_redirect
		if !params[:generate].blank? && !validateERPPermission('A_TE_PRVLG')
			render_403
			return false
		end
	end
	
	def check_setting_admin_perm_and_redirect
		unless validateERPPermission('A_TE_PRVLG')
			render_403
			return false
		end
	end

	def usrsettingsindex
		@status = params[:status] || 1
		@groups = Group.all.sort
		sqlStr = ""
		selectStr = " select u.id as user_id, u.firstname, u.lastname, u.status from users u"
		if !params[:group_id].blank?
			sqlStr = sqlStr + " left join groups_users gu on u.id = gu.user_id"
		end
		sqlStr = sqlStr + " where u.type = 'User' "
		if !validateERPPermission('A_TE_PRVLG')
			sqlStr = sqlStr + " and u.id = #{User.current.id} " 
		end
		if !@status.blank?
			sqlStr = sqlStr + " and u.status = #{@status}"
		end
		if !params[:group_id].blank?
			sqlStr = sqlStr + " and gu.group_id = #{params[:group_id]}"
		end
		if !params[:name].blank?
			sqlStr = sqlStr + " and (LOWER(u.firstname) like LOWER('%#{params[:name]}%') or LOWER(u.lastname) like LOWER('%#{params[:name]}%'))"
		end
		sqlStr = selectStr + sqlStr
		findBySql(sqlStr)
		@salary_components = get_salary_components

		userIds = nil
		if !validateERPPermission('A_TE_PRVLG')
			userIds = User.current.id
		else
			alluserIds = getUsersAndGroups
			userIds = alluserIds.join(',')
		end
		getUserSalaryHash(userIds, Date.today.at_end_of_month + 1)
		@user_salary_components = WkUserSalaryComponents.all
	end
	
	def payrollsettings
		if request.post?
			payrollValues = salaryComponentsHashVal(params[:settings])
			savePayrollSettings(payrollValues)
			params[:taxsettings].each do |key, value|
				taxSettings = WkSetting.where("name = ?", key ).first
				taxSettings = WkSetting.new if taxSettings.blank?
				taxSettings.name = key
				taxSettings.value = value
				taxSettings.save()
			end
			flash[:notice] = l(:notice_successful_update)
			redirect_to action: 'payrollsettings', tab: "payroll"
		else
			retrieveSalarayComponents()
		end
	end

	def salaryComponentsHashVal settinghash
		payrollValues = Hash.new()
		if !settinghash.blank? 
			payrollValues[:basic] = settinghash["basic"]
			payrollValues[:allowances] = settinghash["allowances"]
			payrollValues[:deduction] = settinghash["deduction"]
			payrollValues[:Calculated_Fields] = settinghash["calculated_fields"]
			payrollValues[:comp_del_ids] = settinghash["comp_del_ids"]
			payrollValues[:dep_del_ids] = settinghash["dep_del_ids"]
			payrollValues[:cond_del_ids] = settinghash["cond_del_ids"]
		end
		payrollValues
	end

	def retrieveSalarayComponents
		salary_comps = WkSalaryComponents.all.order('name')
		salaryCompNames = getSalaryCompNames
		condOperators = getLogicalCond.invert
		factorOps = getFactorOperators.invert
		salaryFrequecy = getSalaryFrequency
		salaryTypes = getSalaryType
		ledgers = getLedgerNames
		calculatedFieldTypes = get_calculated_field_types.invert
		hashval = Hash.new()
		hashval["basic"] = []
		hashval["allowances"] = []
		hashval["deduction"] = []
		hashval["calculated_fields"] = []

		salary_comps.each do |list|
			allowCompDeps = []
			allowCompDepsText = []
			deductCompDeps = []
			deductCompDepsText = []
			basicCompDep = ""
			basicCompDepText = ""

			list.salary_comp_deps.each do |dependent|
				comp_cond = dependent.salary_comp_cond
				salaryCompDeps = dependent.id.to_s + '_' + dependent.dependent_id.to_s + '_' + dependent.factor_op.to_s + '_' +
					dependent.factor.to_s + '_' + comp_cond.try(:id).to_s + ':' + comp_cond.try(:lhs).to_s + ':' + 
					comp_cond.try(:operators).to_s + ':' + comp_cond.try(:rhs).to_s + ':' + comp_cond.try(:rhs2).to_s
				salaryCompDepText = salaryCompNames[dependent.dependent_id.to_s].to_s + ':' + factorOps[dependent.factor_op.to_s].to_s + ':' +
					dependent.factor.to_s + ':' + salaryCompNames[comp_cond.try(:lhs).to_s].to_s + ':' +
					condOperators[comp_cond.try(:operators).to_s].to_s + ':' + comp_cond.try(:rhs).to_s + ':' + comp_cond.try(:rhs2).to_s
				case list.component_type
				when 'a'
					allowCompDeps << salaryCompDeps
					allowCompDepsText << salaryCompDepText
				when 'd'
					deductCompDeps << salaryCompDeps
					deductCompDepsText << salaryCompDepText
				end
			end
			if list.component_type == 'b'
				basicCompDep = list.salary_comp_deps.first.try(:id).to_s + '|' + list.salary_comp_deps.first.try(:factor).to_s
				basicCompDepText = list.salary_comp_deps.first.try(:factor)
				hashval["basic"] << [list.name + '|' + salaryTypes[list.salary_type.to_s].to_s + '|' + basicCompDepText.to_s + '|' +
					ledgers[list.ledger_id.to_s].to_s , list.id.to_s + '|' + list.name + '|' + list.salary_type + '|' + basicCompDep + '|' + 
					list.ledger_id.to_s]
			end


			hashval["allowances"] << [list.name + ':' + salaryFrequecy[list.frequency.to_s].to_s + ':' +
				(list.start_date).to_s + ':' + ledgers[list.ledger_id.to_s].to_s + ':' + allowCompDepsText.join(":"),
				list.id.to_s + '|' + list.name + '|' + list.frequency.to_s + '|' + (list.start_date).to_s +
				'|' + list.ledger_id.to_s + '|' + allowCompDeps.join("-")] if list.component_type == 'a'

			hashval["deduction"] << [list.name + ':' + salaryFrequecy[list.frequency.to_s].to_s + ':' +
				(list.start_date).to_s + ':' + ledgers[list.ledger_id.to_s].to_s + ':' +
				deductCompDepsText.join(":"), 
				list.id.to_s + '|' + list.name + '|' + list.frequency.to_s + '|' +
				(list.start_date).to_s + '|' + list.ledger_id.to_s + '|' + deductCompDeps.join("-")] if list.component_type == 'd'

			hashval["calculated_fields"] << [list.name + '|' + calculatedFieldTypes[list.salary_type.to_s].to_s,
				list.id.to_s + '|' + list.name + '|' + list.salary_type] if list.component_type == 'c'
		end
		@payrollsettings = hashval
	end
	    
	def save_bulk_edit
		salary_cmpts = get_salary_components
		u_salary_cmpts = Array.new
		params.each do |key, valueSet|
				salary_cmpts.each do |component|
					keys = key.split('_')
						if keys.first.to_i == component.id && (!(valueSet.first).blank?)
								user_id = keys.last.blank? ? nil : keys.last
								u_salary_cmpts << {:user_id => user_id, :component_id => keys.first,
									:dependent_id => valueSet.last, :factor => valueSet.first, :is_override => 1 }
						end
				end
		end
		errmsg = saveUserSalary(u_salary_cmpts, true)
		errmsg = "ok" if errmsg.blank?
		render :plain => errmsg
	end

	def get_salary_components
		WkSalaryComponents.where("component_type != 'c'")
	end

	def saveUserSalary(u_salary_cmpts, is_bulkEdit)
		return_val = false
		salaryComponents = getSalaryComponentsArr
		errorMsg = nil
		u_salary_cmpts.each do |entry|
				userId = entry["user_id".to_sym]
				componentId = (entry["component_id".to_sym]).to_i
				userSalarycomp = WkUserSalaryComponents.where("user_id = #{userId} and salary_component_id = #{componentId}")
				wkUserSalComp = userSalarycomp[0]
				old_dependent_id = wkUserSalComp.blank? ? 0 : wkUserSalComp.dependent_id
				dependentId = (is_bulkEdit && old_dependent_id.to_i  > 0) ? old_dependent_id.to_i : (entry["dependent_id".to_sym]).to_i
				userSettingHash = getUserSettingHistoryHash(wkUserSalComp) unless wkUserSalComp.blank?
				if (entry["is_override".to_sym]).blank?
						unless wkUserSalComp.blank?
								saveUsrSalCompHistory(userSettingHash) 
								wkUserSalComp.destroy()
						end			
				else
						factor = entry["factor".to_sym]
						if wkUserSalComp.blank?
								wkUserSalComp = WkUserSalaryComponents.new
								wkUserSalComp.user_id = userId
								wkUserSalComp.salary_component_id = componentId
								wkUserSalComp.dependent_id = dependentId if dependentId > 0
								wkUserSalComp.factor = factor 
						else
								wkUserSalComp.dependent_id = dependentId > 0 ? dependentId : nil 
								wkUserSalComp.factor = factor 
						end
						if (wkUserSalComp.changed? && !wkUserSalComp.new_record?) || wkUserSalComp.destroyed?
								saveUsrSalCompHistory(userSettingHash) 
						end
						if !wkUserSalComp.save()
								errorMsg = wkUserSalComp.errors.full_messages.join('\n')
						end
				end
		end
		errorMsg
	end

	def export
		respond_to do |format|
			payrollEntries
			format.csv {
				send_data(payroll_to_csv(@payrollEntries), :type => 'text/csv; header=present', :filename => 'payroll.csv')
			}
		end
	end

	def income_tax
		if params[:action_type] == "calculatetax"
			render json: params[:data]
		end
		getTaxSettingVal
	end

	def getRecursiveComp
		render(plain: getSalCompsByCompType(params[:component_type]))
	end

end