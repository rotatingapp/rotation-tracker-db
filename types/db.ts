export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      crew_assignments: {
        Row: {
          created_at: string | null
          end_date: string | null
          id: string
          position_id: string
          start_date: string
          updated_at: string | null
          user_id: string
        }
        Insert: {
          created_at?: string | null
          end_date?: string | null
          id?: string
          position_id: string
          start_date: string
          updated_at?: string | null
          user_id: string
        }
        Update: {
          created_at?: string | null
          end_date?: string | null
          id?: string
          position_id?: string
          start_date?: string
          updated_at?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_assignments_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "crew_positions"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_positions: {
        Row: {
          created_at: string | null
          id: string
          is_rotating: boolean | null
          rotation_pair_id: string | null
          sort_order: number | null
          title: string
          updated_at: string | null
          vessel_id: string
        }
        Insert: {
          created_at?: string | null
          id?: string
          is_rotating?: boolean | null
          rotation_pair_id?: string | null
          sort_order?: number | null
          title: string
          updated_at?: string | null
          vessel_id: string
        }
        Update: {
          created_at?: string | null
          id?: string
          is_rotating?: boolean | null
          rotation_pair_id?: string | null
          sort_order?: number | null
          title?: string
          updated_at?: string | null
          vessel_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_positions_vessel_id_fkey"
            columns: ["vessel_id"]
            isOneToOne: false
            referencedRelation: "vessels"
            referencedColumns: ["id"]
          },
        ]
      }
      day_locations: {
        Row: {
          created_at: string | null
          date: string
          id: string
          location: string
          updated_at: string | null
          user_id: string
        }
        Insert: {
          created_at?: string | null
          date: string
          id?: string
          location?: string
          updated_at?: string | null
          user_id: string
        }
        Update: {
          created_at?: string | null
          date?: string
          id?: string
          location?: string
          updated_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      important_dates: {
        Row: {
          created_at: string | null
          created_by: string
          date: string
          id: string
          label: string
          priority: number
          recur_yearly: boolean
          user_id: string
        }
        Insert: {
          created_at?: string | null
          created_by?: string
          date: string
          id?: string
          label: string
          priority?: number
          recur_yearly?: boolean
          user_id: string
        }
        Update: {
          created_at?: string | null
          created_by?: string
          date?: string
          id?: string
          label?: string
          priority?: number
          recur_yearly?: boolean
          user_id?: string
        }
        Relationships: []
      }
      notes: {
        Row: {
          content: string
          created_at: string | null
          date: string
          id: string
          updated_at: string | null
          user_id: string
        }
        Insert: {
          content?: string
          created_at?: string | null
          date: string
          id?: string
          updated_at?: string | null
          user_id: string
        }
        Update: {
          content?: string
          created_at?: string | null
          date?: string
          id?: string
          updated_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      org_event_types: {
        Row: {
          created_at: string | null
          default_color: string
          id: string
          name: string
          org_id: string
          sort_order: number | null
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          default_color?: string
          id?: string
          name: string
          org_id: string
          sort_order?: number | null
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          default_color?: string
          id?: string
          name?: string
          org_id?: string
          sort_order?: number | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "org_event_types_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      org_events: {
        Row: {
          color: string | null
          created_at: string | null
          created_by: string
          description: string | null
          end_date: string
          event_type: string
          event_type_id: string | null
          id: string
          start_date: string
          title: string
          updated_at: string | null
          vessel_id: string
        }
        Insert: {
          color?: string | null
          created_at?: string | null
          created_by: string
          description?: string | null
          end_date: string
          event_type: string
          event_type_id?: string | null
          id?: string
          start_date: string
          title: string
          updated_at?: string | null
          vessel_id: string
        }
        Update: {
          color?: string | null
          created_at?: string | null
          created_by?: string
          description?: string | null
          end_date?: string
          event_type?: string
          event_type_id?: string | null
          id?: string
          start_date?: string
          title?: string
          updated_at?: string | null
          vessel_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "org_events_event_type_id_fkey"
            columns: ["event_type_id"]
            isOneToOne: false
            referencedRelation: "org_event_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "org_events_vessel_id_fkey"
            columns: ["vessel_id"]
            isOneToOne: false
            referencedRelation: "vessels"
            referencedColumns: ["id"]
          },
        ]
      }
      org_memberships: {
        Row: {
          accepted_at: string | null
          created_at: string | null
          id: string
          invited_by: string | null
          org_id: string
          role: string
          user_id: string
        }
        Insert: {
          accepted_at?: string | null
          created_at?: string | null
          id?: string
          invited_by?: string | null
          org_id: string
          role?: string
          user_id: string
        }
        Update: {
          accepted_at?: string | null
          created_at?: string | null
          id?: string
          invited_by?: string | null
          org_id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "org_memberships_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string | null
          created_by: string
          id: string
          name: string
          rotation_colors: Json | null
          type: string
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          created_by: string
          id?: string
          name: string
          rotation_colors?: Json | null
          type?: string
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string
          id?: string
          name?: string
          rotation_colors?: Json | null
          type?: string
          updated_at?: string | null
        }
        Relationships: []
      }
      partnerships: {
        Row: {
          created_at: string | null
          id: string
          invitee_email: string | null
          invitee_id: string | null
          inviter_id: string
          link_code: string | null
          status: string
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          id?: string
          invitee_email?: string | null
          invitee_id?: string | null
          inviter_id: string
          link_code?: string | null
          status?: string
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          id?: string
          invitee_email?: string | null
          invitee_id?: string | null
          inviter_id?: string
          link_code?: string | null
          status?: string
          updated_at?: string | null
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string | null
          default_timezone: string | null
          display_name: string | null
          id: string
          settings: Json | null
          updated_at: string | null
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string | null
          default_timezone?: string | null
          display_name?: string | null
          id: string
          settings?: Json | null
          updated_at?: string | null
        }
        Update: {
          avatar_url?: string | null
          created_at?: string | null
          default_timezone?: string | null
          display_name?: string | null
          id?: string
          settings?: Json | null
          updated_at?: string | null
        }
        Relationships: []
      }
      rotation_audit: {
        Row: {
          action: string
          actor_id: string
          actor_role: string
          after_data: Json | null
          before_data: Json | null
          created_at: string | null
          id: string
          rotation_id: string
          user_id: string
        }
        Insert: {
          action: string
          actor_id: string
          actor_role: string
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string | null
          id?: string
          rotation_id: string
          user_id: string
        }
        Update: {
          action?: string
          actor_id?: string
          actor_role?: string
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string | null
          id?: string
          rotation_id?: string
          user_id?: string
        }
        Relationships: []
      }
      rotations: {
        Row: {
          created_at: string | null
          created_via: string | null
          crew_member: string
          end_date: string
          id: string
          is_projected: boolean | null
          location: string | null
          locked: boolean | null
          notes: string | null
          rotation_type: string
          start_date: string
          timezone: string
          updated_at: string | null
          user_id: string
        }
        Insert: {
          created_at?: string | null
          created_via?: string | null
          crew_member: string
          end_date: string
          id?: string
          is_projected?: boolean | null
          location?: string | null
          locked?: boolean | null
          notes?: string | null
          rotation_type: string
          start_date: string
          timezone?: string
          updated_at?: string | null
          user_id: string
        }
        Update: {
          created_at?: string | null
          created_via?: string | null
          crew_member?: string
          end_date?: string
          id?: string
          is_projected?: boolean | null
          location?: string | null
          locked?: boolean | null
          notes?: string | null
          rotation_type?: string
          start_date?: string
          timezone?: string
          updated_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      share_links: {
        Row: {
          created_at: string | null
          id: string
          share_label: string | null
          token: string
          user_id: string
        }
        Insert: {
          created_at?: string | null
          id?: string
          share_label?: string | null
          token?: string
          user_id: string
        }
        Update: {
          created_at?: string | null
          id?: string
          share_label?: string | null
          token?: string
          user_id?: string
        }
        Relationships: []
      }
      vessels: {
        Row: {
          created_at: string | null
          id: string
          imo_number: string | null
          name: string
          org_id: string
          updated_at: string | null
          vessel_type: string | null
        }
        Insert: {
          created_at?: string | null
          id?: string
          imo_number?: string | null
          name: string
          org_id: string
          updated_at?: string | null
          vessel_type?: string | null
        }
        Update: {
          created_at?: string | null
          id?: string
          imo_number?: string | null
          name?: string
          org_id?: string
          updated_at?: string | null
          vessel_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vessels_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_link_code: { Args: { code: string }; Returns: string }
      create_link_code: { Args: never; Returns: string }
      dissolve_partnership: { Args: never; Returns: undefined }
      get_partner_id: { Args: never; Returns: string }
      get_vessel_rotations: {
        Args: { p_end_date: string; p_start_date: string; p_vessel_id: string }
        Returns: {
          avatar_url: string
          crew_member: string
          display_name: string
          end_date: string
          is_projected: boolean
          locked: boolean
          position_sort_order: number
          position_title: string
          rotation_id: string
          rotation_type: string
          start_date: string
          user_id: string
        }[]
      }
      is_manager_of_user: {
        Args: { p_target_user_id: string }
        Returns: boolean
      }
      is_org_creator: { Args: { p_org_id: string }; Returns: boolean }
      is_org_manager: { Args: { p_org_id: string }; Returns: boolean }
      lookup_user_by_email: {
        Args: { p_email: string }
        Returns: {
          avatar_url: string
          display_name: string
          id: string
        }[]
      }
      lookup_user_by_id: {
        Args: { p_user_id: string }
        Returns: {
          avatar_url: string
          display_name: string
          id: string
        }[]
      }
      lookup_users_by_ids: {
        Args: { p_user_ids: string[] }
        Returns: {
          avatar_url: string
          display_name: string
          email: string
          id: string
        }[]
      }
      manager_add_important_date: {
        Args: {
          p_date: string
          p_label: string
          p_priority?: number
          p_recur_yearly?: boolean
          p_user_id: string
        }
        Returns: string
      }
      manager_bulk_create_rotations: {
        Args: { p_rotations: Json; p_user_id: string }
        Returns: number
      }
      manager_delete_important_date: {
        Args: { p_id: string }
        Returns: undefined
      }
      manager_delete_rotation: {
        Args: { p_rotation_id: string }
        Returns: undefined
      }
      manager_set_rotation_lock: {
        Args: { p_locked: boolean; p_rotation_id: string }
        Returns: undefined
      }
      manager_upsert_rotation: {
        Args: {
          p_crew_member: string
          p_end_date: string
          p_location?: string
          p_notes?: string
          p_rotation_id?: string
          p_rotation_type: string
          p_start_date: string
          p_user_id: string
        }
        Returns: string
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
