# We're going to extend the admin theme controller, so we don't repeat all the logic there

class ThemeCreator::ThemeCreatorController < Admin::ThemesController

  requires_login(nil) # Override the blanket "require logged in" from the admin controller
  skip_before_action :ensure_staff # Open up to non-staff

  before_action :ensure_logged_in, except: [:preview, :share_preview, :share_info]

  before_action :ensure_own_theme, only: [:destroy, :update, :create_color_scheme, :update_color_scheme, :destroy_color_scheme]
  before_action :ensure_can_see_theme, only: [:share_preview, :share_info]
  skip_before_action :check_xhr, only: [:preview, :share_preview]

  # Preview is used when actively developing a theme, it uses the GET parameter ?preview_theme_key
  def preview
    @theme ||= Theme.find(params[:id])
    raise Discourse::InvalidAccess.new() if !guardian.can_hotlink_user_theme?(@theme)

    destination = '/styleguide/' if defined? DiscourseStyleguide else '/'
    redirect_to path("#{destination}?preview_theme_key=#{@theme.key}")
  end

  # Shared preview is used when sharing the theme with others. It is only accessible via POST to avoid
  # hotlinking (reduce XSS risk)
  def share_preview
    @theme ||= Theme.find(params[:id])
    raise Discourse::InvalidAccess.new() if !guardian.can_see_user_theme?(@theme)

    destination = '/styleguide/' if defined? DiscourseStyleguide else '/'
    redirect_to path(destination), flash: { user_theme_key: @theme.key }
  end

  def share_info
    @theme ||= Theme.find(params[:id])
    raise Discourse::InvalidAccess.new() if !guardian.can_see_user_theme?(@theme)
    render json: @theme, serializer: ::BasicUserThemeSerializer, root: 'theme'
  end

  def list
    @theme = Theme.where(user_id: current_user.id).order(:name).includes(:theme_fields, :remote_theme)

    # Only present color schemes that are attached to the user's themes
    @color_schemes = ColorScheme.where(theme_id: @theme.pluck(:id)).to_a
    light = ColorScheme.new(name: I18n.t("color_schemes.default"))
    @color_schemes.unshift(light)

    payload = {
      user_themes: ActiveModel::ArraySerializer.new(@theme, each_serializer: ThemeSerializer),
      extras: {
        color_schemes: ActiveModel::ArraySerializer.new(@color_schemes, each_serializer: ColorSchemeSerializer)
      }
    }

    respond_to do |format|
      format.json { render json: payload }
    end
  end

  # def create # Implemented in Admin::ThemesController

  # Mostly using default implementation, but add a security check so users
  # can only set the color scheme to one owned by the current theme
  def update
    @theme ||= Theme.find(params[:id])

    # Set the user_theme specific fields
    [:is_shared].each do |field|
      if theme_params.key?(field)
        @theme.send("#{field}=", theme_params[field])
      end
    end

    # Check color scheme permission
    if theme_params.key?(:color_scheme_id) && !theme_params[:color_scheme_id].nil?
      color_scheme = ColorScheme.find(theme_params[:color_scheme_id])
      if color_scheme.theme_id != @theme.id
        raise Discourse::InvalidAccess.new("Color scheme must be owned by theme.")
      end
    end

    super
  end  

  # def create # Implemented in Admin::ThemesController

  def create_color_scheme
    @theme ||= Theme.find(params[:id])

    new_scheme = ColorScheme.create_from_base(name: I18n.t('theme_creator.new_color_scheme'))
    new_scheme.theme_id = @theme.id
    new_scheme.save!

    @theme.color_scheme_id = new_scheme.id
    @theme.save!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  def update_color_scheme
    @theme ||= Theme.find(params[:id])
    @color_scheme = ColorScheme.find(params[:color_scheme_id])

    # The theme ID has been validated, so just check that this color scheme
    # really does belong to the theme
    if @color_scheme.theme_id != @theme.id
      raise Discourse::InvalidAccess.new("Cannot modify that color scheme.")
    end

    color_scheme_params = params.permit(color_scheme: [:name, colors: [:name, :hex]])[:color_scheme]

    color_scheme = ColorSchemeRevisor.revise(@color_scheme, color_scheme_params)
    if color_scheme.valid?
      render json: color_scheme, root: false
    else
      render_json_error(color_scheme)
    end
  end

  def destroy_color_scheme
    @theme ||= Theme.find(params[:id])
    @color_scheme = ColorScheme.find(params[:color_scheme_id])

    # The theme ID has been validated, so just check that this color scheme
    # really does belong to the theme
    if @color_scheme.theme_id != @theme.id
      raise Discourse::InvalidAccess.new("Cannot modify that color scheme.")
    end

    if @theme.color_scheme_id == @color_scheme.id
      @theme.color_scheme_id = nil
      @theme.save!
    end

    @color_scheme.destroy

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

    # Override with a restricted version
    # Users shouldn't be able to modify:
    #  - :default and :user_selectable
    #  - :child_theme_ids
    # But we want to add
    #  - is_shared
    def theme_params
      @theme_params ||=
        begin
          params.require(:theme).permit(
            :name,
            :is_shared,
            :color_scheme_id,
            # :default,
            # :user_selectable,
            settings: {},
            theme_fields: [:name, :target, :value, :upload_id, :type_id],
            # child_theme_ids: []
          )
        end
    end

    def ensure_can_see_theme
      @theme = Theme.find(params[:id])

      if !guardian.can_see_user_theme?(@theme)

        raise Discourse::InvalidAccess.new("Theme not available.")
      end
    end

    def ensure_own_theme
      @theme = Theme.find(params[:id])
      if @theme.user_id != current_user.id
        raise Discourse::InvalidAccess.new("Cannot modify another user's theme.")
      end
    end

end
