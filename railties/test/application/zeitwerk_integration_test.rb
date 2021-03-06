# frozen_string_literal: true

require "isolation/abstract_unit"
require "active_support/dependencies/zeitwerk_integration"

class ZeitwerkIntegrationTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::Isolation

  def setup
    build_app
  end

  def boot(env = "development")
    app(env)
  end

  def teardown
    teardown_app
  end

  def deps
    ActiveSupport::Dependencies
  end

  def decorated?
    deps.singleton_class < deps::ZeitwerkIntegration::Decorations
  end

  test "ActiveSupport::Dependencies is decorated by default" do
    boot

    assert decorated?
    assert Rails.autoloaders.zeitwerk_enabled?
    assert_instance_of Zeitwerk::Loader, Rails.autoloaders.main
    assert_instance_of Zeitwerk::Loader, Rails.autoloaders.once
    assert_equal [Rails.autoloaders.main, Rails.autoloaders.once], Rails.autoloaders.to_a
  end

  test "ActiveSupport::Dependencies is not decorated in classic mode" do
    add_to_config "config.autoloader = :classic"
    boot

    assert_not decorated?
    assert_not Rails.autoloaders.zeitwerk_enabled?
    assert_nil Rails.autoloaders.main
    assert_nil Rails.autoloaders.once
    assert_equal 0, Rails.autoloaders.count
  end

  test "autoloaders inflect with Active Support" do
    app_file "config/initializers/inflections.rb", <<-RUBY
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.acronym 'RESTful'
      end
    RUBY

    app_file "app/controllers/restful_controller.rb", <<-RUBY
      class RESTfulController < ApplicationController
      end
    RUBY

    boot

    basename  = "restful_controller"
    abspath   = "#{Rails.root}/app/controllers/#{basename}.rb"
    camelized = "RESTfulController"

    Rails.autoloaders.each do |autoloader|
      assert_equal camelized, autoloader.inflector.camelize(basename, abspath)
    end

    assert RESTfulController
  end

  test "constantize returns the value stored in the constant" do
    app_file "app/models/admin/user.rb", "class Admin::User; end"
    boot

    assert_same Admin::User, deps.constantize("Admin::User")
  end

  test "constantize raises if the constant is unknown" do
    boot

    assert_raises(NameError) { deps.constantize("Admin") }
  end

  test "safe_constantize returns the value stored in the constant" do
    app_file "app/models/admin/user.rb", "class Admin::User; end"
    boot

    assert_same Admin::User, deps.safe_constantize("Admin::User")
  end

  test "safe_constantize returns nil for unknown constants" do
    boot

    assert_nil deps.safe_constantize("Admin")
  end

  test "autoloaded_constants returns autoloaded constant paths" do
    app_file "app/models/admin/user.rb", "class Admin::User; end"
    app_file "app/models/post.rb", "class Post; end"
    boot

    assert Admin::User
    assert_equal ["Admin", "Admin::User"], deps.autoloaded_constants
  end

  test "autoloaded? says if a constant has been autoloaded" do
    app_file "app/models/user.rb", "class User; end"
    app_file "app/models/post.rb", "class Post; end"
    boot

    assert Post
    assert deps.autoloaded?("Post")
    assert deps.autoloaded?(Post)
    assert_not deps.autoloaded?("User")
  end

  test "eager loading loads the application code" do
    $zeitwerk_integration_test_user = false
    $zeitwerk_integration_test_post = false

    app_file "app/models/user.rb", "class User; end; $zeitwerk_integration_test_user = true"
    app_file "app/models/post.rb", "class Post; end; $zeitwerk_integration_test_post = true"
    boot("production")

    assert $zeitwerk_integration_test_user
    assert $zeitwerk_integration_test_post
  end

  test "eager loading loads anything managed by Zeitwerk" do
    $zeitwerk_integration_test_user = false
    app_file "app/models/user.rb", "class User; end; $zeitwerk_integration_test_user = true"

    $zeitwerk_integration_test_extras = false
    app_dir "extras"
    app_file "extras/webhook_hacks.rb", "WebhookHacks = 1; $zeitwerk_integration_test_extras = true"

    require "zeitwerk"
    autoloader = Zeitwerk::Loader.new
    autoloader.push_dir("#{app_path}/extras")
    autoloader.setup

    boot("production")

    assert $zeitwerk_integration_test_user
    assert $zeitwerk_integration_test_extras
  end

  test "autoload_paths are set as root dirs of main, and in the same order" do
    boot

    existing_autoload_paths = deps.autoload_paths.select { |dir| File.directory?(dir) }
    assert_equal existing_autoload_paths, Rails.autoloaders.main.dirs
  end

  test "autoload_once_paths go to the once autoloader, and in the same order" do
    extras = %w(e1 e2 e3)
    extras.each do |extra|
      app_dir extra
      add_to_config %(config.autoload_once_paths << "\#{Rails.root}/#{extra}")
    end

    boot

    extras = extras.map { |extra| "#{app_path}/#{extra}" }
    extras.each do |extra|
      assert_not_includes Rails.autoloaders.main.dirs, extra
    end
    assert_equal extras, Rails.autoloaders.once.dirs
  end

  test "clear reloads the main autoloader, and does not reload the once one" do
    boot

    $zeitwerk_integration_reload_test = []

    main_autoloader = Rails.autoloaders.main
    def main_autoloader.reload
      $zeitwerk_integration_reload_test << :main_autoloader
      super
    end

    once_autoloader = Rails.autoloaders.once
    def once_autoloader.reload
      $zeitwerk_integration_reload_test << :once_autoloader
      super
    end

    ActiveSupport::Dependencies.clear

    assert_equal %i(main_autoloader), $zeitwerk_integration_reload_test
  end

  test "verbose = true sets the dependencies logger if present" do
    boot

    logger = Logger.new(File::NULL)
    ActiveSupport::Dependencies.logger = logger
    ActiveSupport::Dependencies.verbose = true

    Rails.autoloaders.each do |autoloader|
      assert_same logger, autoloader.logger
    end
  end

  test "verbose = true sets the Rails logger as fallback" do
    boot

    ActiveSupport::Dependencies.verbose = true

    Rails.autoloaders.each do |autoloader|
      assert_same Rails.logger, autoloader.logger
    end
  end

  test "verbose = false sets loggers to nil" do
    boot

    ActiveSupport::Dependencies.verbose = true
    Rails.autoloaders.each do |autoloader|
      assert autoloader.logger
    end

    ActiveSupport::Dependencies.verbose = false
    Rails.autoloaders.each do |autoloader|
      assert_nil autoloader.logger
    end
  end

  test "unhooks" do
    boot

    assert_equal Module, Module.method(:const_missing).owner
    assert_equal :no_op, deps.unhook!
  end

  test "autoloaders.logger=" do
    boot

    logger = ->(_msg) { }
    Rails.autoloaders.logger = logger

    Rails.autoloaders.each do |autoloader|
      assert_same logger, autoloader.logger
    end

    Rails.autoloaders.logger = Rails.logger

    Rails.autoloaders.each do |autoloader|
      assert_same Rails.logger, autoloader.logger
    end

    Rails.autoloaders.logger = nil

    Rails.autoloaders.each do |autoloader|
      assert_nil autoloader.logger
    end
  end
end
