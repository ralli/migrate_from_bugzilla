# redMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
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
#
# Bugzilla migration by Arjen Roodselaar, Lindix bv
#

desc 'Bugzilla migration script'

require 'active_record'
require 'iconv'
require 'pp'

module ActiveRecord
  namespace :redmine do
    task :migrate_from_bugzilla => :environment do

      module AssignablePk        
        attr_accessor :pk
        def set_pk
          self.id = self.pk unless self.pk.nil?
		  self.id = self.id + 1 if self.class == User
          #puts "id = #{self.id}"
        end
      end

      def self.register_for_assigned_pk(klasses)
        klasses.each do |klass|
          klass.send(:include, AssignablePk)
          klass.send(:before_create, :set_pk)
        end
      end

      register_for_assigned_pk([User, Project, Issue, IssueCategory, Attachment, Version])

      module BugzillaMigrate 
        DEFAULT_STATUS = IssueStatus.default
        CLOSED_STATUS = IssueStatus.find :first, :conditions => { :is_closed => true }
        assigned_status = IssueStatus.find_by_position(2)
        resolved_status = IssueStatus.find_by_position(3)
        feedback_status = IssueStatus.find_by_position(4)
      
        STATUS_MAPPING = {
          "UNCONFIRMED" => DEFAULT_STATUS,
          "NEW" => DEFAULT_STATUS,
          "VERIFIED" => DEFAULT_STATUS,
          "ASSIGNED" => assigned_status,
          "REOPENED" => assigned_status,
          "RESOLVED" => resolved_status,
          "CLOSED" => CLOSED_STATUS
        }
        # actually close resolved issues
        resolved_status.is_closed = true
        resolved_status.save
                        
        priorities = IssuePriority.all(:order => 'id')
        PRIORITY_MAPPING = {
          "P1" => priorities[1], # low
          "P2" => priorities[2], # normal
          "P3" => priorities[3], # high
          "P4" => priorities[4], # urgent
          "P5" => priorities[5]  # immediate
        }
        DEFAULT_PRIORITY = PRIORITY_MAPPING["P2"]
    
        TRACKER_BUG = Tracker.find_by_position(1)
        TRACKER_FEATURE = Tracker.find_by_position(2)
      
        reporter_role = Role.find_by_position(5)
        developer_role = Role.find_by_position(4)
        manager_role = Role.find_by_position(3)
        DEFAULT_ROLE = reporter_role
      
        CUSTOM_FIELD_TYPE_MAPPING = {
          0 => 'string', # String
          1 => 'int',    # Numeric
          2 => 'int',    # Float
          3 => 'list',   # Enumeration
          4 => 'string', # Email
          5 => 'bool',   # Checkbox
          6 => 'list',   # List
          7 => 'list',   # Multiselection list
          8 => 'date',   # Date
        }
                                   
        RELATION_TYPE_MAPPING = {
          0 => IssueRelation::TYPE_DUPLICATES, # duplicate of
          1 => IssueRelation::TYPE_RELATES,    # related to
          2 => IssueRelation::TYPE_RELATES,    # parent of
          3 => IssueRelation::TYPE_RELATES,    # child of
          4 => IssueRelation::TYPE_DUPLICATES  # has duplicate
        }

        class BugzillaProfile < ActiveRecord::Base
          set_table_name :profiles
          set_primary_key :userid
        
          has_and_belongs_to_many :groups,
            :class_name => "BugzillaGroup",
            :join_table => :user_group_map,
            :foreign_key => :user_id,
            :association_foreign_key => :group_id
        
          def login
            login_name[0..29].gsub(/[^a-zA-Z0-9_\-@\.]/, '-')
          end
        
          def email
            if login_name.match(/^.*@.*$/i)
              login_name
            else
              "#{login_name}@foo.bar"
            end
          end
        
          def lastname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/).first
          end

          def firstname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/)[-1]
          end
        end
      
        class BugzillaGroup < ActiveRecord::Base
          set_table_name :groups
        
          has_and_belongs_to_many :profiles,
            :class_name => "BugzillaProfile",
            :join_table => :user_group_map,
            :foreign_key => :group_id,
            :association_foreign_key => :user_id
        end
      
        class BugzillaProduct < ActiveRecord::Base
          set_table_name :products
        
          has_many :components, :class_name => "BugzillaComponent", :foreign_key => :product_id
          has_many :versions, :class_name => "BugzillaVersion", :foreign_key => :product_id
          has_many :bugs, :class_name => "BugzillaBug", :foreign_key => :product_id
        end
      
        class BugzillaComponent < ActiveRecord::Base
          set_table_name :components
        end
      
        class BugzillaVersion < ActiveRecord::Base
          set_table_name :versions
        end
      
        class BugzillaBug < ActiveRecord::Base
          set_table_name :bugs
          set_primary_key :bug_id
        
          belongs_to :product, :class_name => "BugzillaProduct", :foreign_key => :product_id
          has_many :descriptions, :class_name => "BugzillaDescription", :foreign_key => :bug_id
          has_many :attachments, :class_name => "BugzillaAttachment", :foreign_key => :bug_id
        end

        class BugzillaDependency < ActiveRecord::Base
          set_table_name :dependencies
        end
        
        class BugzillaDuplicate < ActiveRecord::Base
          set_table_name :duplicates
        end

        class BugzillaDescription < ActiveRecord::Base
          set_table_name :longdescs
          set_inheritance_column :bongo
          belongs_to :bug, :class_name => "BugzillaBug", :foreign_key => :bug_id
        
          def eql(desc)
            self.bug_when == desc.bug_when
          end
        
          def === desc
            self.eql(desc)
          end
        
          def text
            if self.thetext.blank?
              return nil
            else
              self.thetext
            end
          end
        end


        class BugzillaAttachment < ActiveRecord::Base
          set_table_name :attachments
          set_primary_key :attach_id

          has_one :attach_data, :class_name => 'BugzillaAttachData', :foreign_key => :id


          def size
            return 0 if self.attach_data.nil?
            return self.attach_data.thedata.size
          end

          def original_filename
            return self.filename
          end

          def content_type
            self.mimetype
          end

          def read(*args)
            if @read_finished
              nil
            else
              @read_finished = true
              return nil if self.attach_data.nil?
              return self.attach_data.thedata
            end
          end
        end

        class BugzillaAttachData < ActiveRecord::Base
          set_table_name :attach_data
        end

      
        def self.establish_connection(params)
          constants.each do |const|
            klass = const_get(const)
            next unless klass.respond_to? 'establish_connection'
            puts klass.name
            klass.establish_connection params
          end
        end

        def self.migrate_users
          # Profiles
          puts
          print "Migrating profiles"
          $stdout.flush
          User.delete_all "login <> 'admin'"
          BugzillaProfile.find_each do |profile|
            user = User.new
            user.pk = profile.id
            user.login = profile.login
            user.password = "bugzilla"
            user.firstname = profile.firstname
            user.lastname = profile.lastname
            user.mail = profile.email            
            user.mail.strip!
            user.status = User::STATUS_LOCKED if !profile.disabledtext.empty?
            user.admin = true if profile.groups.include?(BugzillaGroup.find_by_name("admin"))            
            puts "FAILURE #{user.inspect}" unless user.save
            print '.'
            $stdout.flush
          end
        end

        def self.migrate_products
          puts
          print "Migrating products"
          $stdout.flush
          Project.destroy_all
       
          BugzillaProduct.find_each do |product|
            project = Project.new
            project.pk = product.id
            project.name = product.name
            project.description = product.description
            project.identifier = product.name.downcase.gsub(/[^a-zA-Z0-9]+/, '-')[0..19]
            project.save!

            print '.'
            $stdout.flush

            product.versions.each do |version|
              Version.create(:name => version.value, :project => project)
            end
            
            # Enable issue tracking
            enabled_module = EnabledModule.new(
              :project => project,
              :name => 'issue_tracking'
            )
            enabled_module.save!

            # Components
            product.components.each do |component|
              category = IssueCategory.new(:name => component.name[0,30])
              category.pk = component.id
              category.project = project
              category.assigned_to = User.find(component.initialowner)
              category.save
            end

            Tracker.find_each do |tracker|
              project.trackers << tracker
            end

            User.find_each do |user|
              membership = Member.new(
                :user => user,
                :project => project                
              )
              membership.roles << DEFAULT_ROLE
              membership.save
            end
          
          end

        end

        def self.migrate_issues()
          Issue.destroy_all
          BugzillaBug.find_each do |bug|
            description = bug.descriptions.first.text.to_s
            issue = Issue.new(
              :project_id => bug.product_id,
              :subject => bug.short_desc,
              :description => description || bug.short_desc,
              :author_id => bug.reporter,
              :priority => PRIORITY_MAPPING[bug.priority] || DEFAULT_PRIORITY,
              :status => STATUS_MAPPING[bug.bug_status] || DEFAULT_STATUS,
              :start_date => bug.creation_ts,
              :created_on => bug.creation_ts,
              :updated_on => bug.delta_ts
            )

            issue.tracker = TRACKER_BUG
            issue.pk = bug.id
            issue.category_id = bug.component_id
            
            issue.category_id = bug.component_id unless bug.component_id.blank?
            issue.assigned_to_id = bug.assigned_to unless bug.assigned_to.blank?
            version = Version.first(:conditions => {:project_id => bug.product_id, :name => bug.version })
            issue.fixed_version = version
            
            issue.save!
            
            bug.descriptions.each do |description|
              # the first comment is already added to the description field of the bug
              next if description === bug.descriptions.first
              journal = Journal.new(
                :journalized => issue,
                :user_id => description.who,
                :notes => description.text,
                :created_on => description.bug_when
              )
              journal.save!
            end
           
          end
        end
        
        def self.migrate_attachments()
          BugzillaAttachment.find_each() do |attachment|
            next if attachment.attach_data.nil?
            a = Attachment.new :created_on => attachment.creation_ts
            a.file = attachment
            a.author = User.find(attachment.submitter_id) || User.first
            a.container = Issue.find(attachment.bug_id)
            a.save
          end
        end

        def self.migrate_issue_relations()
          BugzillaDependency.find_by_sql("select blocked, dependson from dependencies").each do |dep|
            rel = IssueRelation.new
            rel.issue_from_id = dep.blocked
            rel.issue_to_id = dep.dependson
            rel.relation_type = "blocks"
            rel.save
          end

          BugzillaDuplicate.find_by_sql("select dupe_of, dupe from duplicates").each do |dup|
            rel = IssueRelation.new
            rel.issue_from_id = dup.dupe_of
            rel.issue_to_id = dup.dupe
            rel.relation_type = "duplicates"
            rel.save
          end
        end

        puts
        puts "WARNING: Your Redmine data will be deleted during this process."
        print "Are you sure you want to continue ? [y/N] "
        break unless STDIN.gets.match(/^y$/i)
      
        # Default Bugzilla database settings
        db_params = {:adapter => 'mysql',
          :database => 'bugzilla',
          :host => 'localhost',
          :port => '3306',
          :username => 'bugzilla',
          :password => '',
          :encoding => 'utf8'}

        puts
        puts "Please enter settings for your Bugzilla database"
        [:adapter, :host, :port, :database, :username, :password].each do |param|
            print "#{param} [#{db_params[param]}]: "
            value = STDIN.gets.chomp!
            value = value.to_i if param == :port
            db_params[param] = value unless value.blank?
        end

        # Make sure bugs can refer bugs in other projects
        Setting.cross_project_issue_relations = 1 if Setting.respond_to? 'cross_project_issue_relations'

        # Turn off email notifications
        Setting.notified_events = []
        
        BugzillaMigrate.establish_connection db_params
        BugzillaMigrate.migrate_users
        BugzillaMigrate.migrate_products
        BugzillaMigrate.migrate_issues
        BugzillaMigrate.migrate_attachments
        BugzillaMigrate.migrate_issue_relations
      end   
    end
  end
end
