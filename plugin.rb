# frozen_string_literal: true

# name: discourse-pro-team-downgrade
# about: Downgrades trust level when user leaves all Pro Team groups
# version: 1.0.2
# authors: OX Science
# url: https://github.com/oxscience/discourse-pro-team-downgrade

PRO_USER_GROUP_NAME = "Pro-User"
PRO_TEAMS_CATEGORY_ID = 16
DOWNGRADE_TO_TRUST_LEVEL = 1
STAFF_GROUP_ID = 3

after_initialize do
  module ::ProTeamDowngrade
    def self.still_has_pro_status?(user_id)
      sub_cat_ids = Category.where(parent_category_id: PRO_TEAMS_CATEGORY_ID).pluck(:id)
      pro_group_ids = CategoryGroup.where(category_id: sub_cat_ids).pluck(:group_id).uniq
      if (pro_user = Group.find_by(name: PRO_USER_GROUP_NAME))
        pro_group_ids << pro_user.id
      end
      pro_group_ids -= [STAFF_GROUP_ID]
      GroupUser.where(user_id: user_id, group_id: pro_group_ids).exists?
    end

    def self.was_pro_group?(group)
      return true if group.name == PRO_USER_GROUP_NAME
      sub_cat_ids = Category.where(parent_category_id: PRO_TEAMS_CATEGORY_ID).pluck(:id)
      CategoryGroup.where(group_id: group.id, category_id: sub_cat_ids).exists?
    end
  end

  module ::Jobs
    class ProTeamEnforceDowngrade < ::Jobs::Base
      def execute(args)
        user = User.find_by(id: args[:user_id])
        return unless user
        return if user.staff?
        return if ::ProTeamDowngrade.still_has_pro_status?(user.id)
        return if user.trust_level == DOWNGRADE_TO_TRUST_LEVEL

        old_tl = user.trust_level
        # Direct update bypasses Discourse's auto-downgrade re-trigger
        user.update_columns(trust_level: DOWNGRADE_TO_TRUST_LEVEL)
        user.reload

        Rails.logger.info(
          "[pro-team-downgrade] #{user.username}: TL#{old_tl} -> TL#{user.trust_level} " \
            "(trigger: #{args[:trigger_group_name]})"
        )
      rescue => e
        Rails.logger.error("[pro-team-downgrade] Job error: #{e.message}")
      end
    end
  end

  DiscourseEvent.on(:user_removed_from_group) do |user, group|
    begin
      next if user.staff?
      next unless ::ProTeamDowngrade.was_pro_group?(group)
      next if ::ProTeamDowngrade.still_has_pro_status?(user.id)

      # Defer by 5s so Discourse's own auto-downgrade runs first.
      Jobs.enqueue_in(
        5.seconds,
        :pro_team_enforce_downgrade,
        user_id: user.id,
        trigger_group_name: group.name
      )
    rescue => e
      Rails.logger.error("[pro-team-downgrade] Event error: #{e.message}")
    end
  end
end
