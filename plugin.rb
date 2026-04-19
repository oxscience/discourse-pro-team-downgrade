# frozen_string_literal: true

# name: discourse-pro-team-downgrade
# about: Auto-manages trust level for Pro Team group members (upgrade on join, downgrade on leave)
# version: 1.1.0
# authors: OX Science
# url: https://github.com/oxscience/discourse-pro-team-downgrade

PRO_USER_GROUP_NAME = "Pro-User"
PRO_TEAMS_CATEGORY_ID = 16
UPGRADE_TO_TRUST_LEVEL = 4
DOWNGRADE_TO_TRUST_LEVEL = 1
STAFF_GROUP_ID = 3

after_initialize do
  module ::ProTeamDowngrade
    # A group is "Pro" if it has permissions on at least one Pro Teams subcategory
    # or if it is the Pro-User group itself. Staff group is excluded.
    def self.is_pro_group?(group)
      return false if group.id == STAFF_GROUP_ID
      return true if group.name == PRO_USER_GROUP_NAME
      sub_cat_ids = Category.where(parent_category_id: PRO_TEAMS_CATEGORY_ID).pluck(:id)
      CategoryGroup.where(group_id: group.id, category_id: sub_cat_ids).exists?
    end

    def self.still_has_pro_status?(user_id)
      sub_cat_ids = Category.where(parent_category_id: PRO_TEAMS_CATEGORY_ID).pluck(:id)
      pro_group_ids = CategoryGroup.where(category_id: sub_cat_ids).pluck(:group_id).uniq
      if (pro_user = Group.find_by(name: PRO_USER_GROUP_NAME))
        pro_group_ids << pro_user.id
      end
      pro_group_ids -= [STAFF_GROUP_ID]
      GroupUser.where(user_id: user_id, group_id: pro_group_ids).exists?
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

  # UPGRADE: when a user is added to a Pro group, bump TL to 4 if not already.
  # This works even if the group's grant_trust_level isn't set — the plugin
  # handles it dynamically based on the group's Pro-Teams-subcategory permissions.
  DiscourseEvent.on(:user_added_to_group) do |user, group, options = nil|
    begin
      next if user.staff?
      next unless ::ProTeamDowngrade.is_pro_group?(group)
      next if user.trust_level >= UPGRADE_TO_TRUST_LEVEL

      old_tl = user.trust_level
      user.update_columns(trust_level: UPGRADE_TO_TRUST_LEVEL)
      Rails.logger.info(
        "[pro-team-upgrade] #{user.username}: TL#{old_tl} -> TL#{UPGRADE_TO_TRUST_LEVEL} " \
          "(added to #{group.name})"
      )
    rescue => e
      Rails.logger.error("[pro-team-upgrade] Event error: #{e.message}")
    end
  end

  # DOWNGRADE: when a user is removed from a Pro group and has no remaining Pro
  # group membership, schedule a deferred downgrade to TL1 (after 5s, so
  # Discourse's own grant_trust_level auto-downgrade runs first).
  DiscourseEvent.on(:user_removed_from_group) do |user, group|
    begin
      next if user.staff?
      next unless ::ProTeamDowngrade.is_pro_group?(group)
      next if ::ProTeamDowngrade.still_has_pro_status?(user.id)

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
