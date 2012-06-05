## This is kind of a hack, to ensure that the cookbook can be
#  loaded. On first load, nokogiri may not be present. It is
#  installed at load time by recipes/default.rb, so that at run
#  time nokogiri will be present.
#
begin
  require 'nokogiri'
rescue LoadError
  Chef::Log.warn("Missing gem 'nokogiri'")
end

require 'forwardable'

module SMF
  class XMLWriter
    # allow delegation
    extend Forwardable

    attr_reader :resource

    # delegate methods to :resource
    def_delegators :resource, :name, :environment, :locale, :manifest_type, :service_path, :working_directory, :duration, :property_groups
    def_delegator :resource, :credentials_user, :user

    public

    def initialize(smf_resource)
      @resource = smf_resource
    end

    def to_xml
      @xml_output ||= xml_output
    end

    protected

    ## methods that need to be called from within the context
    #  of the Nokogiri builder block need to be protected, rather
    #  than private.

    def commands
      @commands ||= {
        "start" => resource.start_command,
        "stop" => resource.stop_command,
        "restart" => resource.restart_command
      }
    end

    def timeout
      @timeouts ||= {
        "start" => resource.start_timeout,
        "stop" => resource.stop_timeout,
        "restart" => resource.restart_timeout
      }
    end

    def default_dependencies
      [
        {:name => "milestone", :value => "/milestone/sysconfig"},
        {:name => "fs-local", :value => "/system/filesystem/local"},
        {:name => "name-services", :value => "/milestone/name-services"},
        {:name => "network", :value => "/milestone/network"}
      ]
    end

    private

    def xml_output
      xml_builder = ::Nokogiri::XML::Builder.new do |builder|
        builder.doc.create_internal_subset("service_bundle", nil, "/usr/share/lib/xml/dtd/service_bundle.dtd.1")
        builder.service_bundle_(:name => name, :type => "manifest") {
          builder.service_(:name => "#{manifest_type}/management/#{name}", :type => "service", :version => "1") {
            builder.create_default_instance_(:enabled => "false")
            builder.single_instance_

            self.default_dependencies.each do |dependency|
              builder.dependency_(:name => dependency[:name], :grouping => "require_all", :restart_on => "none", :type => "service") {
                builder.service_fmri_(:value => "svc:#{dependency[:value]}")
              }
            end

            self.commands.each_pair do |type, command|
              if command
                builder.exec_method_(:type => "method", :name => type, :exec => command, :timeout_seconds => self.timeout[type]) {
                  builder.method_context_(exec_context) {
                    if user != "root"
                      builder.method_credential_(:user => user, :privileges => "basic,net_privaddr")
                    end
                    
                    if self.environment
                      builder.method_environment_ {
                        self.environment.each_pair do |var, value|
                          builder.envvar_(:name => var, :value => value)
                        end
                      }
                    end
                  }
                }
              end
            end

            builder.property_group_(:name => "general", :type => "framework") {
              builder.propval_(:name => "action_authorization", :type => "astring", :value => "solaris.smf.manage.#{name}")
              builder.propval_(:name => "value_authorization", :type => "astring", :value => "solaris.smf.value.#{name}")
            }
            
            if duration != "contract"
              builder.property_group_(:name => "startd", :type => "framework") {
                builder.propval_(:name => "duration", :type => "astring", :value => duration)
              }
            end
            
            property_groups.each_pair do |name, properties|
              builder.property_group_(:name => name, :type => properties.delete("type"){ |type| "application" }) {
                properties.each_pair do |key, value|
                  builder.propval_(:name => key, :value => value, :type => check_type(value))
                end
              }
            end

            builder.template_ {
              builder.common_name_ {
                builder.loctext_("xml:lang" => locale) {
                  builder.text name
                }
              }
            }
          }
        }
      end
      xml_builder.to_xml
    end
    
    def exec_context
      {:working_directory => working_directory} unless working_directory.nil?
    end
    
    def check_type(value)
      if value == value.to_i
        "integer"
      else
        "astring"
      end
    end
  end
end
